require 'sinatra/base'
require 'mysql2'
require 'mysql2-cs-bind'
require 'tilt/erubis'
require 'erubis'
require 'logger'
require 'dalli'

module Isucon5
  class AuthenticationError < StandardError; end
  class PermissionDenied < StandardError; end
  class ContentNotFound < StandardError; end
  module TimeWithoutZone
    def to_s
      strftime("%F %H:%M:%S")
    end
  end
  ::Time.prepend TimeWithoutZone
end

class Isucon5::WebApp < Sinatra::Base
  use Rack::Session::Cookie
  set :erb, escape_html: true
  set :public_folder, File.expand_path('../../static', __FILE__)
  #set :sessions, true
  set :session_secret, ENV['ISUCON5_SESSION_SECRET'] || 'beermoris'
  set :protection, true
  #set :renderd_html, {}
  set :logger, Logger.new(File.expand_path('log/logger.log', __dir__))

  configure :production do
    settings.logger.info 'configure:production called.'
    path = File.expand_path('static', __dir__)
    set :render_401, File.read(File.join(path, '401.html'))
    set :render_403, File.read(File.join(path, '403.html'))
    set :render_404, File.read(File.join(path, '404.html'))
    set :render_login, File.read(File.join(path, 'login.html'))
    #@renderd_html = {}
    #static = File.expand_path('static', __dir__)
    #@renderd_html[:login_fail] = File.read(File.join(static, 'login_fail.html'))

    set :dc, Dalli::Client.new('localhost:11211', { :namespace => "isucon5q", :compress => true })
  end

  helpers do
    def config
      @config ||= {
        db: {
          # host: ENV['ISUCON5_DB_HOST'] || 'localhost',
          # port: ENV['ISUCON5_DB_PORT'] && ENV['ISUCON5_DB_PORT'].to_i,
          socket: '/var/run/mysqld/mysqld.sock',
          username: ENV['ISUCON5_DB_USER'] || 'root',
          password: ENV['ISUCON5_DB_PASSWORD'],
          database: ENV['ISUCON5_DB_NAME'] || 'isucon5q',
        },
      }
    end

    def db
      return Thread.current[:isucon5_db] if Thread.current[:isucon5_db]
      client = Mysql2::Client.new(
        # host: config[:db][:host],
        # port: config[:db][:port],
        socket: config[:db][:socket],
        username: config[:db][:username],
        password: config[:db][:password],
        database: config[:db][:database],
        reconnect: true,
      )
      client.query_options.merge!(symbolize_keys: true)
      Thread.current[:isucon5_db] = client
      client
    end

    def authenticate(email, password)
      query = <<SQL
SELECT u.id AS id, u.account_name AS account_name, u.nick_name AS nick_name, u.email AS email
FROM users u
JOIN salts s ON u.id = s.user_id
WHERE u.email = ? AND u.passhash = SHA2(CONCAT(?, s.salt), 512)
SQL
      result = db.xquery(query, email, password).first
      unless result
        raise Isucon5::AuthenticationError
      end
      session[:user_id] = result[:id]
      result
    end

    def current_user
      return @user if @user
      unless session[:user_id]
        return nil
      end
      @user = db.xquery('SELECT id, account_name, nick_name, email FROM users WHERE id=?', session[:user_id]).first
      unless @user
        session[:user_id] = nil
        session.clear
        raise Isucon5::AuthenticationError
      end
      @user
    end

    def authenticated!
      unless current_user
        redirect '/login'
      end
    end

    def get_user(user_id)
      user = db.xquery('SELECT * FROM users WHERE id = ?', user_id).first
      raise Isucon5::ContentNotFound unless user
      user
    end

    def user_from_account(account_name)
      user = db.xquery('SELECT * FROM users WHERE account_name = ?', account_name).first
      raise Isucon5::ContentNotFound unless user
      user
    end

    def is_friend?(another_id)
      # query = 'SELECT COUNT(1) AS cnt FROM relations WHERE one = ? AND another = ?'
      # cnt = db.xquery(query, user_id, another_id).first[:cnt]
      # cnt.to_i > 0 ? true : false

      user_id = session[:user_id]
      !settings.dc.get(user_id.to_s).split(',').index(another_id.to_s).nil?
    end

    def is_friend_account?(account_name)
      is_friend?(user_from_account(account_name)[:id])
    end

    def permitted?(another_id)
      another_id == current_user[:id] || is_friend?(another_id)
    end

    def mark_footprint(user_id)
      if user_id != current_user[:id]
        query = 'INSERT INTO footprints (user_id,owner_id) VALUES (?,?)'
        db.xquery(query, user_id, current_user[:id])
      end
    end

    PREFS = %w(
      未入力
      北海道 青森県 岩手県 宮城県 秋田県 山形県 福島県 茨城県 栃木県 群馬県 埼玉県 千葉県 東京都 神奈川県 新潟県 富山県
      石川県 福井県 山梨県 長野県 岐阜県 静岡県 愛知県 三重県 滋賀県 京都府 大阪府 兵庫県 奈良県 和歌山県 鳥取県 島根県
      岡山県 広島県 山口県 徳島県 香川県 愛媛県 高知県 福岡県 佐賀県 長崎県 熊本県 大分県 宮崎県 鹿児島県 沖縄県
    )
    def prefectures
      PREFS
    end
  end

  error Isucon5::AuthenticationError do
    session[:user_id] = nil
    halt 401, settings.render_401
  end

  error Isucon5::PermissionDenied do
    halt 403, settings.render_403
  end

  error Isucon5::ContentNotFound do
    halt 404, settings.render_404
  end

  get '/login' do
    session.clear
    #erb :login, layout: false, locals: { message: '高負荷に耐えられるSNSコミュニティサイトへようこそ!' }
    settings.render_login
  end

  post '/login' do
    authenticate params['email'], params['password']
    redirect '/'
  end

  get '/logout' do
    session[:user_id] = nil
    session.clear
    redirect '/login'
  end

  get '/' do
    authenticated!
    settings.logger.info '/: START'

    profile = db.xquery('SELECT * FROM profiles WHERE user_id = ?', current_user[:id]).first
    settings.logger.info '/: profile end'

    entries_query = 'SELECT * FROM entries WHERE user_id = ? ORDER BY created_at LIMIT 5'
    entries = db.xquery(entries_query, current_user[:id])
      .map{ |entry| entry[:is_private] = (entry[:private] == 1); entry[:title], entry[:content] = entry[:body].split(/\n/, 2); entry }
    settings.logger.info '/: entries_query end'

    comments_for_me_query = <<SQL
SELECT c.id AS id, c.entry_id AS entry_id, c.user_id AS user_id, c.comment AS comment, c.created_at AS created_at, u.account_name AS user_account_name, u.nick_name AS user_nick_name
FROM comments c
JOIN users u ON u.id = c.user_id
JOIN entries e ON c.entry_id = e.id
WHERE e.user_id = ?
ORDER BY c.created_at DESC
LIMIT 10
SQL
    comments_for_me = db.xquery(comments_for_me_query, current_user[:id])
    settings.logger.info '/: comments_for_me end'

    entries_of_friends = []
    db.query('SELECT SQL_CACHE * FROM entries ORDER BY created_at DESC LIMIT 1000').each do |entry|
          next unless is_friend?(entry[:user_id])
          entry[:title] = entry[:body].split(/\n/).first
          entries_of_friends << entry
          break if entries_of_friends.size >= 10
    end
    settings.logger.info '/: entries_of_friends end'

    comments_of_friends = []
    db.query('SELECT SQL_CACHE * FROM comments ORDER BY created_at DESC LIMIT 1000').each do |comment|
      next unless is_friend?(comment[:user_id])
      entry = db.xquery('SELECT * FROM entries WHERE id = ?', comment[:entry_id]).first
      entry[:is_private] = (entry[:private] == 1)
      next if entry[:is_private] && !permitted?(entry[:user_id])
      comments_of_friends << comment
      break if comments_of_friends.size >= 10
    end
    settings.logger.info '/: comments_of_friends end'

    friends_query = 'SELECT one, another, created_at FROM relations WHERE one = ? OR another = ? ORDER BY created_at DESC'
    friends_map = {}
    db.xquery(friends_query, current_user[:id], current_user[:id]).each do |rel|
      key = (rel[:one] == current_user[:id] ? :another : :one)
      friends_map[rel[key]] ||= rel[:created_at]
    end
    friends = friends_map.map{|user_id, created_at| [user_id, created_at]}
    settings.logger.info '/: friends_map end'

    query = <<SQL
SELECT user_id, owner_id, DATE(created_at) AS date, MAX(created_at) AS updated
FROM footprints
WHERE user_id = ?
GROUP BY user_id, owner_id, DATE(created_at)
ORDER BY updated DESC
LIMIT 10
SQL
    footprints = db.xquery(query, current_user[:id])
    settings.logger.info '/: footprints end'

    locals = {
      profile: profile || {},
      entries: entries,
      comments_for_me: comments_for_me,
      entries_of_friends: entries_of_friends,
      comments_of_friends: comments_of_friends,
      friends: friends,
      footprints: footprints
    }

    settings.logger.info '/: END'

    erb :index, locals: locals
  end

  get '/profile/:account_name' do
    authenticated!
    owner = user_from_account(params['account_name'])
    prof = db.xquery('SELECT * FROM profiles WHERE user_id = ?', owner[:id]).first
    prof = {} unless prof
    query = if permitted?(owner[:id])
              'SELECT * FROM entries WHERE user_id = ? ORDER BY created_at LIMIT 5'
            else
              'SELECT * FROM entries WHERE user_id = ? AND private=0 ORDER BY created_at LIMIT 5'
            end
    entries = db.xquery(query, owner[:id])
      .map{ |entry| entry[:is_private] = (entry[:private] == 1); entry[:title], entry[:content] = entry[:body].split(/\n/, 2); entry }
    mark_footprint(owner[:id])
    erb :profile, locals: { owner: owner, profile: prof, entries: entries, private: permitted?(owner[:id]) }
  end

  post '/profile/:account_name' do
    authenticated!
    if params['account_name'] != current_user[:account_name]
      raise Isucon5::PermissionDenied
    end
    args = [params['first_name'], params['last_name'], params['sex'], params['birthday'], params['pref']]

    prof = db.xquery('SELECT * FROM profiles WHERE user_id = ?', current_user[:id]).first
    if prof
      query = <<SQL
UPDATE profiles
SET first_name=?, last_name=?, sex=?, birthday=?, pref=?, updated_at=CURRENT_TIMESTAMP()
WHERE user_id = ?
SQL
      args << current_user[:id]
    else
      query = <<SQL
INSERT INTO profiles (user_id,first_name,last_name,sex,birthday,pref) VALUES (?,?,?,?,?,?)
SQL
      args.unshift(current_user[:id])
    end
    db.xquery(query, *args)
    redirect "/profile/#{params['account_name']}"
  end

  get '/diary/entries/:account_name' do
    authenticated!
    owner = user_from_account(params['account_name'])
    query = if permitted?(owner[:id])
              'SELECT * FROM entries WHERE user_id = ? ORDER BY created_at DESC LIMIT 20'
            else
              'SELECT * FROM entries WHERE user_id = ? AND private=0 ORDER BY created_at DESC LIMIT 20'
            end
    entries = db.xquery(query, owner[:id])
      .map{ |entry| entry[:is_private] = (entry[:private] == 1); entry[:title], entry[:content] = entry[:body].split(/\n/, 2); entry }
    mark_footprint(owner[:id])
    erb :entries, locals: { owner: owner, entries: entries, myself: (current_user[:id] == owner[:id]) }
  end

  get '/diary/entry/:entry_id' do
    authenticated!
    entry = db.xquery('SELECT * FROM entries WHERE entries.id = ?', params['entry_id']).first
    raise Isucon5::ContentNotFound unless entry
    entry[:title], entry[:content] = entry[:body].split(/\n/, 2)
    entry[:is_private] = (entry[:private] == 1)
    owner = get_user(entry[:user_id])
    if entry[:is_private] && !permitted?(owner[:id])
      raise Isucon5::PermissionDenied
    end
    comments = db.xquery('SELECT * FROM comments, users WHERE comments.entry_id = ? AND users.id = comments.user_id', entry[:id])
    mark_footprint(owner[:id])
    erb :entry, locals: { owner: owner, entry: entry, comments: comments }
  end

  post '/diary/entry' do
    authenticated!
    query = 'INSERT INTO entries (user_id, private, body) VALUES (?,?,?)'
    body = (params['title'] || "タイトルなし") + "\n" + params['content']
    db.xquery(query, current_user[:id], (params['private'] ? '1' : '0'), body)
    redirect "/diary/entries/#{current_user[:account_name]}"
  end

  post '/diary/comment/:entry_id' do
    authenticated!
    entry = db.xquery('SELECT * FROM entries WHERE id = ?', params['entry_id']).first
    unless entry
      raise Isucon5::ContentNotFound
    end
    entry[:is_private] = (entry[:private] == 1)
    if entry[:is_private] && !permitted?(entry[:user_id])
      raise Isucon5::PermissionDenied
    end
    query = 'INSERT INTO comments (entry_id, user_id, comment) VALUES (?,?,?)'
    db.xquery(query, entry[:id], current_user[:id], params['comment'])
    redirect "/diary/entry/#{entry[:id]}"
  end

  get '/footprints' do
    authenticated!
    query = <<SQL
SELECT fp.user_id, fp.owner_id, DATE(fp.created_at) AS date, MAX(fp.created_at) as updated, u.account_name, u.nick_name
FROM footprints fp
JOIN users u ON fp.owner_id = u.id
WHERE fp.user_id = ?
GROUP BY fp.user_id, fp.owner_id, DATE(fp.created_at)
ORDER BY updated DESC
LIMIT 50;
SQL
    footprints = db.xquery(query, current_user[:id])
    erb :footprints, locals: { footprints: footprints }
  end

  get '/friends' do
    authenticated!
    query = <<SQL
SELECT u.account_name, u.nick_name, f.created_at FROM
(SELECT another friend_id, created_at FROM relations WHERE one = ? ORDER BY created_at DESC) f
JOIN users u ON f.friend_id = u.id;
SQL
    friends = db.xquery(query, current_user[:id])
    erb :friends, locals: { friends: friends }
  end

  post '/friends/:account_name' do
    authenticated!
    unless is_friend_account?(params['account_name'])
      user = user_from_account(params['account_name'])
      unless user
        raise Isucon5::ContentNotFound
      end
      db.xquery('INSERT INTO relations (one, another) VALUES (?,?), (?,?)', current_user[:id], user[:id], user[:id], current_user[:id])

      # 友達との関連をmemcachedに持たせる
      my_cache = settings.dc.get(current_user[:id])
      friend_cache = settings.dc.get(user[:id])

      settings.dc.set(current_user[:id], my_cache + ",#{user[:id]}")
      settings.dc.set(user[:id], friend_cache + ",#{current_user[:id]}")

      redirect '/friends'
    end
  end

  get '/initialize' do
    db.query("DELETE FROM relations WHERE id > 500000")
    db.query("DELETE FROM footprints WHERE id > 500000")
    db.query("DELETE FROM entries WHERE id > 500000")
    db.query("DELETE FROM comments WHERE id > 1500000")

    # 友達のIDを初期化時にmemcachedに叩き込む
    db.query('SELECT one me, GROUP_CONCAT(another) friend_ids FROM relations GROUP BY one;').each do |friendship|
      settings.dc.set(friendship[:me], friendship[:friend_ids])
    end

    status 200
    body ''
  end
end
