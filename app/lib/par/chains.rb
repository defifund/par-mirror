# par deployments, copied from par-sdk src/addresses.ts (v0.3.0). Only chains listed in
# PAR_CHAINS (default "4663") are indexed and shown.
module Par
  module Chains
    ZERO = "0x0000000000000000000000000000000000000000".freeze
    DEAD = "0x000000000000000000000000000000000000dead".freeze

    EVM_PAR = {
      factory: "0x02E9EE8527f4AFF58f7a1E08B1b898637ce718e9", router: "0xE721a861b32dEc68230101EA576304a63ebeEacd",
      locker: "0xE5B0B35F4927004fE8c0E437030723Eb80F6C32E", multi_factory: "0x920Ca489f8c9573645b8aB00dad60fc81c9487fd",
      multi_router: "0x7cda46222a6B202f6B18A51b9a558Bc38a655083", multi_locker: "0x344A4A773Df4FFa89AE6Dc4f1418123990a34647",
      fee_escrow: "0x96AB924F958da3a8d83fCdF5Ce692653fCEea9fD", quote_pricer: "0xcebC312381D1F816da478Acc8A37711808909d90",
      fee_splitter: "0x031f3D93A94c5F34EE3e608566245AAC271523A9", holder_vault: "0x64D085E5269fdAFfc28363f21b208f8A2EfCcD0A",
      burn_vault: "0x4067820296a0C717c3e31B05E98505b3215c5544", floor_vault: "0x5567633b002f935181f0fEAa8953Bd0ad5610b0D",
      disperse: "0x372A36543d29F00053161BCAD1cCCCC595a7cA88", buyback_wallet: "0x5bA4a4A197111CE8B6a2C2776D7836A9E1868033",
      holders_wallet: "0xB1a7a3A37F41e4dC9507F9B0F946B7F786c4AFb4", par: ZERO
    }.freeze

    DEFS = {
      4663 => {
        slug: "rh", name: "Robinhood Chain", rpc: "https://rpc.mainnet.chain.robinhood.com",
        explorer: "https://robinhoodchain.blockscout.com", deploy_block: 53_890_474, log_span: 100_000,
        ts_granularity: 10_000, rps: 12, # measured: max 6.8 s interpolation error even at 100k-block spacing
        reference: { symbol: "ETH", decimals: 18, native: true, address: ZERO, wrapped: "0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73", usd_is_one: false },
        position_manager: "0x58daec3116aae6D93017bAAea7749052E8a04fA7",
        addresses: {
          factory: "0x9d33Ba78389c8772bC114Cba47Dc1985E933e76F", router: "0x73d84bdbB1983Fa7eD8FCBcE40bc308997cEd120",
          locker: "0x8a6d37B2E6a2AC7970eF69d2932757F04be0A231", multi_factory: "0x3ea29975a79900179F3e1aEF93347Ba4210c29C1",
          multi_router: "0x458D2a59c2F3dd32775a64eE72004561440d64Df", multi_locker: "0x5826FBB6201DaAcD924A3d292841DA9142952D59",
          fee_escrow: "0x1C27e8F0c2a754DB23ab1608fA09c068D54d4386", quote_pricer: "0x9EfC6EFA4c5F31e2BEC6CC174Ba7bB8f0b57d563",
          fee_splitter: "0x85a1CbbE2933F15f2599B9E0e03e6F89655fa4C1", holder_vault: "0x4B79B8298cd890A82dC9De1dE5dBb745Cf04353C",
          burn_vault: "0x16c83D36539b6C92E6FC998D2a039fD7Ff31958E", floor_vault: "0xA5e805856e513F01d6aC992aC45FE54E5e601829",
          disperse: "0x28a5f3F898E99753E322fdce6EFa8b294C215B9b", buyback_wallet: "0x5bA4a4A197111CE8B6a2C2776D7836A9E1868033",
          holders_wallet: "0xB1a7a3A37F41e4dC9507F9B0F946B7F786c4AFb4", par: "0x507B6F349a80114097A67B8b4677367acC15b220",
          pool_manager: "0x8366a39CC670B4001A1121B8F6A443A643e40951", weth: "0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73",
          usdg: "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168"
        }
      },
      8453 => {
        slug: "base", name: "Base", rpc: "https://base-rpc.publicnode.com", explorer: "https://basescan.org",
        deploy_block: 51_489_805, log_span: 10_000, ts_granularity: 500, rps: 6, max_addresses: 10,
        reference: { symbol: "ETH", decimals: 18, native: true, address: ZERO, wrapped: "0x4200000000000000000000000000000000000006", usd_is_one: false },
        position_manager: "0x7C5f5A4bBd8fD63184577525326123B519429bDc",
        addresses: EVM_PAR.merge(pool_manager: "0x498581fF718922c3f8e6A244956aF099B2652b2b", weth: "0x4200000000000000000000000000000000000006",
                                 usdg: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913")
      },
      5042 => {
        slug: "arc", name: "Arc", rpc: "https://rpc.mainnet.arc.io", explorer: "https://arcscan.app",
        deploy_block: 21_074_807, log_span: 2_000, ts_granularity: 500, rps: 4, max_addresses: 20, # node rejects >20 addresses as "requested range too large"
        reference: { symbol: "USDC", decimals: 6, native: false, address: "0x3600000000000000000000000000000000000000", wrapped: "0x3600000000000000000000000000000000000000", usd_is_one: true },
        position_manager: "0x6049c9a0e26405C0985f9E3685C87d0aE917f82B",
        addresses: EVM_PAR.merge(pool_manager: "0x8366a39CC670B4001A1121B8F6A443A643e40951", weth: "0x3600000000000000000000000000000000000000",
                                 usdg: "0xbef5f6d51cb62b58e6a8f77868681825c6fe21c1")
      },
      56 => {
        slug: "bnb", name: "BNB Chain", rpc: "https://bsc-rpc.publicnode.com", explorer: "https://bscscan.com",
        deploy_block: 122_881_639, log_span: 1_000, ts_granularity: 500, rps: 6, max_addresses: 10,
        reference: { symbol: "BNB", decimals: 18, native: true, address: ZERO, wrapped: "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c", usd_is_one: false },
        position_manager: "0x7A4a5c919aE2541AeD11041A1AEeE68f1287f95b",
        addresses: EVM_PAR.merge(
          factory: "0x456645ad38d099358Cb95ff743736663CDB31a25", router: "0x9DF1B1687f95Ce8a42fC8c861F767B6D52C346ab",
          locker: "0xBE14efB8d23346730025902813AF1bE4a4955eb3", multi_factory: "0x6715d9C03590F0e7b11A7Cd5bab2eAD4F77e666A",
          multi_router: "0x7b62174524f0c2d4c475ac05ee9a6F893D625a10", multi_locker: "0x03136E9FE0be1943191Cf022EFa40B436CDdCBdE",
          fee_escrow: "0x389216d9F1A3BC72415Ddf16cA50Ca5Bf8B5b065", quote_pricer: "0x335b39437637A09d791848eB675E5F8D290bba71",
          fee_splitter: "0xD713367eD15bC42BF23Ef2D449629053A16a30D9", holder_vault: "0xb9E88952596F56f090A36D2FE2B37F50A29dd459",
          burn_vault: "0x5EAE87d4AaF8196079B009234938C0F5Baa79578", floor_vault: "0x3b90bef8FA9694B46a01d5E4073937fB913F1799",
          disperse: "0x589576e4f610B85DBd7a06015acEacF732DD9828", pool_manager: "0x28e2Ea090877bF75740558f6BFB36A5ffeE9e9dF",
          weth: "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c", usdg: "0x55d398326f99059fF775485246999027B3197955"
        )
      }
    }.freeze

    Chain = Struct.new(:id, :slug, :name, :rpc, :explorer, :deploy_block, :log_span, :ts_granularity, :rps,
                       :max_addresses, :reference, :position_manager, :addresses, keyword_init: true) do
      def addr(key) = addresses.fetch(key).downcase
      def to_public_h
        { id:, slug:, name:, rpc: ENV.fetch("PAR_PUBLIC_RPC_#{id}", rpc), explorer:, reference:,
          addresses: addresses.transform_keys { |k| k.to_s.gsub(/_(\w)/) { $1.upcase } } }
      end
    end

    module_function

    def enabled_ids = ENV.fetch("PAR_CHAINS", "4663,8453,5042").split(",").map { |s| id_for(s.strip) }

    def id_for(slug_or_id)
      return slug_or_id if slug_or_id.is_a?(Integer)
      DEFS.find { |_, d| d[:slug] == slug_or_id }&.first || Integer(slug_or_id)
    end

    def get(slug_or_id)
      id = id_for(slug_or_id)
      d = DEFS.fetch(id) { raise ArgumentError, "unsupported chain #{slug_or_id}" }
      Chain.new(
        id:, slug: d[:slug], name: d[:name],
        rpc: ENV.fetch("PAR_RPC_URL_#{id}", d[:rpc]), explorer: d[:explorer],
        deploy_block: Integer(ENV.fetch("PAR_START_BLOCK_#{id}", d[:deploy_block])),
        log_span: Integer(ENV.fetch("PAR_LOG_SPAN_#{id}", d[:log_span])),
        ts_granularity: d[:ts_granularity], rps: Float(ENV.fetch("PAR_RPS_#{id}", d[:rps])),
        max_addresses: Integer(ENV.fetch("PAR_MAX_SELECTORS_#{id}", ENV["PAR_RPC_URL_#{id}"] ? 900 : (d[:max_addresses] || 900))),
        reference: d[:reference], position_manager: d[:position_manager], addresses: d[:addresses]
      )
    end

    def enabled = enabled_ids.map { get(_1) }
  end
end
