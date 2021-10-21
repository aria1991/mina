package main

import (
	"codanet"
	"context"
	"errors"
	"fmt"
	ipc "libp2p_ipc"
	"time"

	blocks "github.com/ipfs/go-block-format"
	"github.com/ipfs/go-cid"
	blockstore "github.com/ipfs/go-ipfs-blockstore"
	exchange "github.com/ipfs/go-ipfs-exchange-interface"
	logging "github.com/ipfs/go-log"
)

var bitswapLogger = logging.Logger("mina.helper.bitswap")

type root BitswapBlockLink

// IsValidMaxBlockSize checks that maxBlobSize is not too short
// and has padding that allows to store at least 5 bytes of data in root
// block even in case of root block being full occupied with links
// P.S. all multiples of 32b are valid
func IsValidMaxBlockSize(maxBlobSize int) bool {
	return maxBlobSize >= 7+BITSWAP_BLOCK_LINK_SIZE && (maxBlobSize-2)%BITSWAP_BLOCK_LINK_SIZE >= 5
}

type BitswapDataTag byte

const (
	BlockBodyTag BitswapDataTag = iota
	// EpochLedger // uncomment in future to serve epoch ledger via Bitswap
)

type BitswapDataConfig struct {
	maxSize         int
	downloadTimeout time.Duration
}

type RootDownloadState struct {
	allDescedants        *cid.Set
	session              exchange.Fetcher
	ctx                  context.Context
	cancelF              context.CancelFunc
	schema               *BitswapBlockSchema
	tag                  BitswapDataTag
	remainingNodeCounter int
}

type RootParams interface {
	getSchema() *BitswapBlockSchema
	setSchema(*BitswapBlockSchema)
	getTag() BitswapDataTag
}

func (s *RootDownloadState) getSchema() *BitswapBlockSchema {
	return s.schema
}

func (s *RootDownloadState) setSchema(schema *BitswapBlockSchema) {
	if s.schema != nil {
		bitswapLogger.Warn("Double set schema for RootDownloadState")
	}
	s.schema = schema
}

func (s *RootDownloadState) getTag() BitswapDataTag {
	return s.tag
}

type BitswapState interface {
	codanet.BitswapStorage
	NodeDownloadParams() map[cid.Cid]map[root][]NodeIndex
	RootDownloadStates() map[root]*RootDownloadState
	MaxBlockSize() int
	DataConfig() map[BitswapDataTag]BitswapDataConfig
	DepthIndices() DepthIndices
	Context() context.Context
	NewSession(ctx context.Context) exchange.Fetcher
	DeadlineChan() chan<- root
	FreeRoot(root)
	SendResourceUpdate(type_ ipc.ResourceUpdateType, roots ...BitswapBlockLink)
	AsyncDownloadBlocks(ctx context.Context, session exchange.Fetcher, cids []cid.Cid) error
}

// kickStartRootDownload initiates downloading of root block
func kickStartRootDownload(root_ BitswapBlockLink, tag BitswapDataTag, bs BitswapState) {
	rootCid := codanet.BlockHashToCid(root_)
	nodeDownloadParams := bs.NodeDownloadParams()
	rootDownloadStates := bs.RootDownloadStates()
	_, has := nodeDownloadParams[rootCid]
	if has {
		bitswapLogger.Debugf("Skipping download request for %s (downloading already in progress)", codanet.BlockHashToCid(root_))
		return // downloading already in progress
	}
	dataConf, hasDC := bs.DataConfig()[tag]
	if !hasDC {
		bitswapLogger.Errorf("Tag %d is not supported by Bitswap downloader", tag)
	}
	err := bs.SetStatus(root_, codanet.Partial)
	if err != nil {
		bitswapLogger.Debugf("Skipping download request for %s due to status: %w", codanet.BlockHashToCid(root_), err)
		status, err := bs.GetStatus(root_)
		if err == nil && status == codanet.Full {
			bs.SendResourceUpdate(ipc.ResourceUpdateType_added, root_)
		}
		return
	}
	s2 := cid.NewSet()
	s2.Add(rootCid)
	downloadTimeout := dataConf.downloadTimeout
	ctx, cancelF := context.WithTimeout(bs.Context(), downloadTimeout)
	session := bs.NewSession(ctx)
	np, hasNP := nodeDownloadParams[rootCid]
	if !hasNP {
		np = map[root][]NodeIndex{}
		nodeDownloadParams[rootCid] = np
	}
	np[root_] = append(np[root_], 0)
	rootDownloadStates[root_] = &RootDownloadState{
		allDescedants:        s2,
		ctx:                  ctx,
		session:              session,
		cancelF:              cancelF,
		tag:                  tag,
		remainingNodeCounter: 1,
	}
	var rootBlock []byte
	err = bs.ViewBlock(root_, func(b []byte) error {
		rootBlock := make([]byte, len(b))
		copy(rootBlock, b)
		return nil
	})
	hasRootBlock := err == nil
	if err == blockstore.ErrNotFound {
		err = bs.AsyncDownloadBlocks(ctx, session, []cid.Cid{rootCid})
		bitswapLogger.Debugf("Requested download of %s", codanet.BlockHashToCid(root_))
	}
	if err == nil {
		go func() {
			<-time.After(downloadTimeout)
			_, has := bs.RootDownloadStates()[root_]
			if has {
				bs.DeadlineChan() <- root_
			}
		}()
	} else {
		bitswapLogger.Errorf("Error initializing block download: %w", err)
		bs.FreeRoot(root_)
	}
	if hasRootBlock {
		b, _ := blocks.NewBlockWithCid(rootBlock, rootCid)
		processDownloadedBlock(b, bs)
	}
}

type malformedRoots map[root]error

// processDownloadedBlockImpl is a small-step transition of root block retrieval state machine
// It calculates state transition for a single block
func processDownloadedBlockImpl(params map[root][]NodeIndex, block blocks.Block, rootParams map[root]RootParams,
	maxBlockSize int, di DepthIndices, tagConfig map[BitswapDataTag]BitswapDataConfig) (map[BitswapBlockLink]map[root][]NodeIndex, malformedRoots) {
	id := block.Cid()
	malformed := make(malformedRoots)
	links, fullBlockData, err := ReadBitswapBlock(block.RawData())
	if err != nil {
		for root := range params {
			malformed[root] = fmt.Errorf("Error reading block %s: %v", id, err)
		}
		return nil, malformed
	}
	children := make(map[BitswapBlockLink]map[root][]NodeIndex)
	for root_, ixs := range params {
		rp, hasRp := rootParams[root_]
		if !hasRp {
			bitswapLogger.Errorf("processBlock: didn't find root state for %s (root %s)",
				id, codanet.BlockHashToCid(root_))
			continue
		}
		schema := rp.getSchema()
		hasRootIx := false
		for _, ix := range ixs {
			if ix == 0 {
				hasRootIx = true
				break
			}
		}
		if hasRootIx {
			blockData, dataLen, err := ExtractLengthFromRootBlockData(fullBlockData)
			if err == nil && len(blockData) < 1 {
				err = errors.New("error reading tag from block")
			}
			tag := rp.getTag()
			if err == nil {
				tag_ := BitswapDataTag(blockData[0])
				if tag_ != tag {
					err = fmt.Errorf("tag mismatch: %d != %d", tag_, tag)
				}
			}
			if err == nil {
				dataConf, hasDataConf := tagConfig[tag]
				if !hasDataConf {
					err = fmt.Errorf("no tag config for tag %d", tag)
				} else if dataConf.maxSize < dataLen-1 {
					err = fmt.Errorf("data is too large: %d > %d", dataLen-1, dataConf.maxSize)
				}
			}
			if err != nil {
				malformed[root_] = fmt.Errorf("error reading root block %s: %v", id, err)
				continue
			}
			schema_ := MkBitswapBlockSchemaLengthPrefixed(maxBlockSize, dataLen)
			schema = &schema_
			rp.setSchema(schema)
		}
		if schema == nil {
			bitswapLogger.Errorf("Invariant broken for %s (root %s): schema not set for non-root block",
				id, codanet.BlockHashToCid(root_))
			continue
		}
		for _, ix := range ixs {
			if len(block.RawData()) != schema.BlockSize(ix) {
				malformed[root_] = fmt.Errorf("unexpected size for block #%d (%s) of root %s: %d != %d",
					ix, id, codanet.BlockHashToCid(root_), len(block.RawData()), schema.BlockSize(ix))
				break
			}
			if len(links) != schema.LinkCount(ix) {
				malformed[root_] = fmt.Errorf("unexpected link count for block %s of root %s: %d != %d (fullLinkBlocks: %d, ix: %d)",
					id, codanet.BlockHashToCid(root_), len(links), schema.LinkCount(ix), schema.fullLinkBlocks, ix)
				break
			}
			fstChildId := di.FirstChildId(ix)
			for childIx, link := range links {
				if children[link] == nil {
					children[link] = make(map[root][]NodeIndex)
				}
				children[link][root_] = append(children[link][root_], fstChildId+NodeIndex(childIx))
			}
		}
	}
	return children, malformed
}

// processDownloadedBlock is a big-step transition of root block retrieval state machine
// It transits state for a single block
func processDownloadedBlock(block blocks.Block, bs BitswapState) {
	id := block.Cid()
	nodeDownloadParams := bs.NodeDownloadParams()
	rootDownloadStates := bs.RootDownloadStates()
	depthIndices := bs.DepthIndices()
	oldPs, foundRoot := nodeDownloadParams[id]
	delete(nodeDownloadParams, id)
	if !foundRoot {
		bitswapLogger.Warnf("Didn't find node download params for block: %s", id)
		// TODO remove from storage
		return
	}
	rps := make(map[root]RootParams)
	// Can not just pass the `rootDownloadStates` map to processBlock function :(
	for root, ixs := range oldPs {
		rootState, hasRS := rootDownloadStates[root]
		if !hasRS {
			bitswapLogger.Errorf("processDownloadedBlock: didn't find root state for %s (root %s)",
				id, codanet.BlockHashToCid(root))
			continue
		}
		rootState.remainingNodeCounter = rootState.remainingNodeCounter - len(ixs)
		rps[root] = rootState
	}
	newParams, malformed := processDownloadedBlockImpl(oldPs, block, rps, bs.MaxBlockSize(), depthIndices, bs.DataConfig())
	for root, err := range malformed {
		bitswapLogger.Warnf("Block %s of root %s is malformed: %s", id, codanet.BlockHashToCid(root), err)
		bs.FreeRoot(root)
		bs.SendResourceUpdate(ipc.ResourceUpdateType_broken, root)
	}

	blocksToProcess := make([]blocks.Block, 0)
	toDownload := make([]cid.Cid, 0)
	var someRootState *RootDownloadState
	for link, ps := range newParams {
		childId := codanet.BlockHashToCid(link)
		np, has := nodeDownloadParams[childId]
		if !has {
			np = make(map[root][]NodeIndex)
			nodeDownloadParams[childId] = np
		}
		for root, ixs := range ps {
			np[root] = append(np[root], ixs...)
			rootState, hasRS := rootDownloadStates[root]
			if !hasRS {
				bitswapLogger.Errorf("processDownloadedBlock (2): didn't find root state for %s (root %s)",
					id, codanet.BlockHashToCid(root))
				continue
			}
			someRootState = rootState
			rootState.allDescedants.Add(childId)
			rootState.remainingNodeCounter = rootState.remainingNodeCounter + len(ixs)
		}
		var blockBytes []byte
		err := bs.ViewBlock(link, func(b []byte) error {
			blockBytes = make([]byte, len(b))
			copy(blockBytes, b)
			return nil
		})
		if err == nil {
			b, _ := blocks.NewBlockWithCid(blockBytes, childId)
			blocksToProcess = append(blocksToProcess, b)
		} else {
			if err != blockstore.ErrNotFound {
				// we still schedule blocks for downloading
				// this case should rarely happen in practice
				bitswapLogger.Warnf("Failed to retrieve block %s from storage: %w", childId, err)
			}
			toDownload = append(toDownload, childId)
		}
	}
	if len(toDownload) > 0 {
		// It's fine to use someRootState because all blocks from toDownload
		// inevitably belong to each root, so any will do
		bs.AsyncDownloadBlocks(someRootState.ctx, someRootState.session, toDownload)
	}
	for root := range oldPs {
		rootState, hasRS := rootDownloadStates[root]
		if hasRS && rootState.remainingNodeCounter == 0 {
			// clean-up
			err := bs.SetStatus(root, codanet.Full)
			if err != nil {
				bitswapLogger.Warnf("Failed to update status of fully downloaded root %s: %s", root, err)
			}
			bs.FreeRoot(root)
			bs.SendResourceUpdate(ipc.ResourceUpdateType_added, root)
		}
	}
	for _, b := range blocksToProcess {
		processDownloadedBlock(b, bs)
	}
}