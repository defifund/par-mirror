Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  root "explore#index"
  get "token/:chain/:token", to: "tokens#show", as: :token, constraints: { token: /0x\h{40}/ }
  get "token/:token", to: "tokens#show", constraints: { token: /0x\h{40}/ }
  get "t/:token", to: "tokens#show", constraints: { token: /0x\h{40}/ }
  get "t/:id", to: "tokens#short", constraints: { id: /\h{16}/ } # original short links in token metadata
  get "launch", to: "launches#new", as: :new_launch
  get "portfolio", to: "portfolios#show", as: :portfolio
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
  scope "idx/:chain", controller: "api/indexer", defaults: { format: :json } do
    get "health"
    get "launches/count", action: :count
    get "launches/:token", action: :launch, constraints: { token: /0x\h{40}/ }
    get "launches"
    %w[trades candles holders positions fees claimable burns buybacks stats distributions rewards floor resolve].each { get _1 }
    get "tokenlist.json", action: :tokenlist
  end
end
