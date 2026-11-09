import { application } from "./application"
import WalletController from "./wallet_controller"
import TradeController from "./trade_controller"
import FeesController from "./fees_controller"
import ChartController from "./chart_controller"
import CreateController from "./create_controller"
import PortfolioController from "./portfolio_controller"
import TabsController from "./tabs_controller"
import CopyController from "./copy_controller"
import FallbackController from "./fallback_controller"
import AutosubmitController from "./autosubmit_controller"
import RewardsController from "./rewards_controller"
import LiveController from "./live_controller"
import SiweController from "./siwe_controller"
import ColumnsController from "./columns_controller"

application.register("wallet", WalletController)
application.register("trade", TradeController)
application.register("fees", FeesController)
application.register("chart", ChartController)
application.register("create", CreateController)
application.register("portfolio", PortfolioController)
application.register("tabs", TabsController)
application.register("copy", CopyController)
application.register("fallback", FallbackController)
application.register("autosubmit", AutosubmitController)
application.register("columns", ColumnsController)
application.register("rewards", RewardsController)
application.register("live", LiveController)
application.register("siwe", SiweController)
