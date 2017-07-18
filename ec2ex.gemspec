# -*- encoding: utf-8 -*-

require File.expand_path('../lib/ec2ex/version', __FILE__)

Gem::Specification.new do |gem|
  gem.name          = "ec2ex"
  gem.version       = Ec2ex::VERSION
  gem.summary       = %q{ec2 expand command line}
  gem.description   = %q{ec2 expand command line}
  gem.license       = "MIT"
  gem.authors       = ["Hiroshi Toyama"]
  gem.email         = "toyama0919@gmail.com"
  gem.homepage      = "https://github.com/toyama0919/ec2ex"

  gem.files         = `git ls-files`.split($/)
  gem.executables   = gem.files.grep(%r{^bin/}).map{ |f| File.basename(f) }
  gem.test_files    = gem.files.grep(%r{^(test|spec|features)/})
  gem.require_paths = ['lib']

  gem.add_dependency 'thor'
  gem.add_dependency 'hashie'
  gem.add_dependency 'ipaddress'
  gem.add_dependency 'aws-sdk'
  gem.add_dependency 'activesupport'
  gem.add_dependency 'parallel'
  gem.add_dependency 'net-ping'
  gem.add_dependency 'terminal-table'

  gem.add_development_dependency 'bundler'
  gem.add_development_dependency 'pry', '~> 0.10.1'
  gem.add_development_dependency 'rake', '~> 10.3.2'
  gem.add_development_dependency 'rspec', '~> 2.4'
  gem.add_development_dependency 'rubocop', '~> 0.24.1'
  gem.add_development_dependency 'rubygems-tasks', '~> 0.2'
  gem.add_development_dependency 'yard', '~> 0.8'
end
