worker_processes 6
preload_app true
listen 8080
pid "/home/isucon/webapp/ruby/unicorn.pid"
listen "/tmp/unicorn.sock"

#stderr_path File.expand_path('log/unicorn_stderr.log', __dir__)
#stdout_path File.expand_path('log/unicorn_stdout.log', __dir__)
