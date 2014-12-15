gem 'rspec', '~> 2.4'
require 'rspec'
require 'ec2ex/version'

include Ec2ex

def capture_stdout
  out = StringIO.new
  $stdout = out
  yield
  return out.string
ensure
  $stdout = STDOUT
end

def capture_stderr
  out = StringIO.new
  $stderr = out
  yield
  return out.string
ensure
  $stderr = STDERR
end

