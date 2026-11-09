class LaunchesController < ApplicationController
  def new
    @upload = UploadsController.enabled?
  end
end
