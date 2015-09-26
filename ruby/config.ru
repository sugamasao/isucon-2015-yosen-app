require 'rack-lineprof'
require_relative './app.rb'

use Rack::Lineprof
run Isucon5::WebApp
