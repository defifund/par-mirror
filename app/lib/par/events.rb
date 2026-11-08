# Event declarations (from par-sdk abi.ts / the contracts) and the view signatures the indexer reads.
module Par
  module Events
    E = ->(decl) { Abi.event(decl) }

    TOKEN_LAUNCHED       = E["TokenLaunched(address indexed token, bytes32 indexed poolId, address indexed deployer, address pairToken, uint256 launchConfigId, uint24 poolFee)"]
    POSITION_MINTED      = E["LaunchPositionMinted(address indexed token, uint256 positionId, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 tokenAmount, uint256 phantomQuote)"]
    MULTI_LAUNCHED       = E["TokenLaunched(address indexed token, address indexed deployer, uint256 launchConfigId, uint24 poolFee, address[] pairTokens)"]
    MARKET_OPENED        = E["MarketOpened(address indexed token, bytes32 indexed poolId, uint256 marketIndex, address pairToken, uint256 positionId, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 tokenAmount, uint256 phantomQuote)"]
    RECIPIENT_UPDATED    = E["CreatorFeeRecipientUpdated(address indexed token, address indexed previousRecipient, address indexed newRecipient)"]
    FEES_COLLECTED       = E["FeesCollected(address indexed token, address currency0, address currency1, uint256 protocolAmount0, uint256 protocolAmount1, uint256 creatorAmount0, uint256 creatorAmount1)"]
    MULTI_FEES_COLLECTED = E["FeesCollected(address indexed token, uint256 indexed marketIndex, address currency0, address currency1, uint256 protocolAmount0, uint256 protocolAmount1, uint256 creatorAmount0, uint256 creatorAmount1)"]
    SWAP                 = E["Swap(bytes32 indexed id, address indexed sender, int128 amount0, int128 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick, uint24 fee)"]
    TRANSFER             = E["Transfer(address indexed from, address indexed to, uint256 value)"]

    # single-factory LaunchedToken struct
    LAUNCHED_TOKEN = "(address,address,address,address,uint256,uint24,int24,int24,int24,uint128,uint256,uint16,uint16,uint16,address,uint64,bool)".freeze
    LAUNCHED_TOKEN_FIELDS = %i[token deployer creator_fee_recipient pair_token phantom_quote pool_fee tick_spacing tick_lower tick_upper
                               liquidity position_id base_fee_bps creator_tax_bps protocol_fee_share_bps protocol_fee_recipient launched_at exists].freeze
    # multi-factory LaunchedToken struct and Market[]
    MULTI_LAUNCHED_TOKEN = "(address,address,address,uint24,int24,uint16,uint16,uint16,address,uint64,uint8,bool)".freeze
    MULTI_LAUNCHED_TOKEN_FIELDS = %i[token deployer creator_fee_recipient pool_fee tick_spacing base_fee_bps creator_tax_bps protocol_fee_share_bps
                                     protocol_fee_recipient launched_at market_count exists].freeze
    MARKETS = "(address,uint256,int24,int24,uint128,uint256)[]".freeze
    MARKET_FIELDS = %i[pair_token phantom_quote tick_lower tick_upper liquidity position_id].freeze
    TOKEN_INFO = %w[address string string (string,string,string,string,string)].freeze
    LAUNCH_CONFIG = "(uint256,uint256,int24,bool)".freeze
  end
end
