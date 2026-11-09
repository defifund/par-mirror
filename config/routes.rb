Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check
  get "health" => "health#show" # external monitor: indexer, rows, host memory (503 when unhealthy)
  get "locale/:code", to: "locales#update", as: :locale, constraints: { code: /en|zh-CN|zh-TW/ }

  root "explore#index"
  get "token/:chain/:token", to: "tokens#show", as: :token, constraints: { token: /0x\h{40}/ }
  get "token/:token", to: "tokens#show", constraints: { token: /0x\h{40}/ }
  get "t/:token", to: "tokens#show", constraints: { token: /0x\h{40}/ }
  get "t/:id", to: "tokens#short", constraints: { id: /\h{16}/ } # original short links in token metadata
  get "launch", to: "launches#new", as: :new_launch
  get "portfolio", to: "portfolios#show", as: :portfolio
  get "profile", to: "profiles#edit", as: :profile
  patch "profile", to: "profiles#update"
  get "token/:chain/:token/edit", to: "token_profiles#edit", as: :edit_token, constraints: { token: /0x\h{40}/ }
  patch "token/:chain/:token/edit", to: "token_profiles#update", constraints: { token: /0x\h{40}/ }
  post "api/auth/message", to: "auth#message"
  post "api/auth/verify", to: "auth#verify"
  delete "api/auth", to: "auth#destroy"
  get "stats", to: "stats#show", as: :stats
  get "docs", to: "pages#docs", as: :docs
  get "api/config", to: "pages#config_json"
  get "tokenlist.json", to: "api/indexer#tokenlist"
  post "api/upload", to: "uploads#create"
  get "ipfs/:cid(/*path)", to: "ipfs#show", as: :ipfs, format: false
  get "api/stocks", to: "api/create_helpers#stocks"
  get "api/tokens", to: "api/create_helpers#tokens"

  # API compatible with the original public indexer (api.par.family / par.family/idx/<chainId>)
  get "idx/:chain/events", to: "api/events#index"
  # public read-only MCP server for AI agents (app/mcp_tools)
  mount ParMcpApp.new => "/mcp"
  scope "idx/:chain", controller: "api/indexer", defaults: { format: :json } do
    get "health"
    get "launches/count", action: :count
    get "launches/:token", action: :launch, constraints: { token: /0x\h{40}/ }
    get "launches"
    %w[trades candles holders positions fees claimable burns buybacks stats distributions rewards floor resolve pulse].each { get _1 }
    get "tokenlist.json", action: :tokenlist
  end
end
