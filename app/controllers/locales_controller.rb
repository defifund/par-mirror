# GET /locale/:code — remember the visitor's language and go back to the page they were on
class LocalesController < ApplicationController
  def update
    code = params[:code].to_s
    cookies.permanent[:locale] = { value: code, same_site: :lax } if LOCALES.include?(code)
    redirect_back fallback_location: root_path
  end
end
