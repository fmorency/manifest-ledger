package keeper

import (
	"github.com/liftedinit/manifest-ledger/x/manifest/types"

	"cosmossdk.io/errors"
)

var (
	ErrGettingMinter         = errors.Register(types.ModuleName, 1, "getting minter in ante handler")
	ErrManualMintingDisabled = errors.Register(types.ModuleName, 2, "manual minting is disabled due to inflation being >0")
)