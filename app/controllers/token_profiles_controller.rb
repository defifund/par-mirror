# /token/:chain/:token/edit: the creator corrects a token's description, image and links on this mirror.
class TokenProfilesController < ApplicationController
  before_action :load
  rate_limit to: 30, within: 1.hour, only: :update

  def edit; end

  def update
    @tp.assign_attributes(params.require(:token_profile).permit(:description, :logo, socials: TokenProfile::SOCIALS))
    @tp.updated_by = current_wallet
    if @tp.save
      redirect_to token_path(chain: current_chain.slug, token: @launch.token), notice: t("token_edit.saved")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def load
    @launch = Launch.find_by(chain_id: current_chain.id, token: params[:token].to_s.downcase) or return render("tokens/missing", status: :not_found)
    @allowed = TokenProfile.editor?(@launch, current_wallet)
    return render(:edit, status: :forbidden) unless @allowed || (action_name == "edit")
    @tp = TokenProfile.find_or_initialize_by(chain_id: current_chain.id, token: @launch.token)
  end
end
