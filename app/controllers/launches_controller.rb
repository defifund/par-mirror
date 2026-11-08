class LaunchesController < ApplicationController
  def new
    @upload = ENV["PINATA_JWT"].present?
  end
end
