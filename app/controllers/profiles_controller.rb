# /profile: a name, a short bio, an image and links next to your address, after a wallet signature.
class ProfilesController < ApplicationController
  rate_limit to: 30, within: 1.hour, only: :update

  def edit
    return unless current_wallet
    @profile = Profile.find_or_initialize_by(address: current_wallet)
    @tokens = Launch.where(deployer: current_wallet).or(Launch.where(creator_fee_recipient: current_wallet))
                    .order(launched_at: :desc).limit(100).to_a
  end

  def update
    return redirect_to(profile_path) unless current_wallet
    @profile = Profile.find_or_initialize_by(address: current_wallet)
    @profile.assign_attributes(params.require(:profile).permit(:name, :bio, :avatar, socials: Profile::SOCIALS))
    if @profile.save
      redirect_to profile_path, notice: "Profile saved."
    else
      @tokens = []
      render :edit, status: :unprocessable_entity
    end
  end
end
