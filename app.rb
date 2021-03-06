require "sinatra"
require 'koala'

enable :sessions
set :raise_errors, false
set :show_exceptions, false

use Rack::Logger

# Scope defines what permissions that we are asking the user to grant.
# In this example, we are asking for the ability to publish stories
# about using the app, access to what the user likes, and to be able
# to use their pictures.  You should rewrite this scope with whatever
# permissions your app needs.
# See https://developers.facebook.com/docs/reference/api/permissions/
# for a full list of permissions
FACEBOOK_SCOPE = 'user_likes,user_photos,user_photo_video_tags,user_groups'

unless ENV["FACEBOOK_APP_ID"] && ENV["FACEBOOK_SECRET"]
  abort("missing env vars: please set FACEBOOK_APP_ID and FACEBOOK_SECRET with your app credentials")
end


if settings.environment != :production
  Koala.http_service.http_options = {
     :ssl => {:verify => false}
  }
end

before do
  # HTTPS redirect
  if settings.environment == :production && request.scheme != 'https'
    redirect "https://#{request.env['HTTP_HOST']}"
  end
end

helpers do
  def logger
    request.logger
  end

  def host
    request.env['HTTP_HOST']
  end

  def scheme
    request.scheme
  end

  def url_no_scheme(path = '')
    "//#{host}#{path}"
  end

  def url(path = '')
    "#{scheme}://#{host}#{path}"
  end

  def authenticator
    @authenticator ||= Koala::Facebook::OAuth.new(ENV["FACEBOOK_APP_ID"], ENV["FACEBOOK_SECRET"], url("/auth/facebook/callback"))
  end

  def get_users(conn)
    user_ids = []
    conn.each do |item|
      if item["from"]
        user_ids << item["from"]["id"]
      end
    end
    users_str = user_ids.join(",")
    query = "select uid,name,pic_square from user where uid in (#{users_str}) ;"
    result = @graph.fql_query(query)
    users = {}
    result.each do |user|
      users[user["uid"].to_s] = user
    end
    users
  end

end

# the facebook session expired! reset ours and restart the process
error(Koala::Facebook::APIError) do
  session[:access_token] = nil
  redirect "/auth/facebook"
end

get "/" do
  # Get base API Connection
  @graph  = Koala::Facebook::API.new(session[:access_token])

  # Get public details of current application
  @app  =  @graph.get_object(ENV["FACEBOOK_APP_ID"])

  if session[:access_token]
    @user    = @graph.get_object("me")
    @friends = @graph.get_connections('me', 'friends')
    @photos  = @graph.get_connections('me', 'photos')
    @likes   = @graph.get_connections('me', 'likes').first(4)
    @groups  = @graph.get_connections('me', 'groups').first(10)
    @posters   = {}

    @group_id = params[:group_id]
    if @group_id
      @group = @graph.get_object(@group_id)
      @group_conn = @graph.get_connections(@group_id, 'feed',{'limit'=>50})

      @posters = get_users(@group_conn)
    end

    # for other data you can always run fql
    @friends_using_app = @graph.fql_query("SELECT uid, name, is_app_user, pic_square FROM user WHERE uid in (SELECT uid2 FROM friend WHERE uid1 = me()) AND is_app_user = 1")
  end
  erb :index
end

# used by Canvas apps - redirect the POST to be a regular GET
post "/" do
  redirect "/"
end

# used by Canvas apps - redirect the POST to be a regular GET
post "/wall" do

  # Get base API Connection
  @graph  = Koala::Facebook::API.new(session[:access_token])

  # Get public details of current application
  @app  =  @graph.get_object(ENV["FACEBOOK_APP_ID"])

  if session[:access_token]
    @user    = @graph.get_object("me")

    @group_id = params[:group_id]
    logger.info "@group_id=#{@group_id}"

    if @group_id
      @group = @graph.get_object(@group_id)
      logger.info "@group=#{@group}"

      @graph.put_object(@group_id, "feed", :message=>params[:message], :link=>params[:link])
      redirect "/?group_id=#{@group_id}"
    end

  end
  redirect '/'
end

# used to close the browser window opened to post to wall/send to friends
get "/close" do
  "<body onload='window.close();'/>"
end

get "/sign_out" do
  session[:access_token] = nil
  redirect '/'
end

get "/auth/facebook" do
  session[:access_token] = nil
##  redirect authenticator.url_for_oauth_code(:permissions => FACEBOOK_SCOPE)
  redirect authenticator.url_for_oauth_code(:permissions => "publish_stream")
end

get '/auth/facebook/callback' do
	session[:access_token] = authenticator.get_access_token(params[:code])
	redirect '/'
end
