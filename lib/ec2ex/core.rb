require 'aws-sdk'
require "logger"

module Ec2ex
  class Core
    attr_reader :client
    attr_reader :elb_client
    attr_reader :logger

    def initialize
      ENV['AWS_REGION'] = ENV['AWS_REGION'] || Metadata.get_document['region']
      @client = Aws::EC2::Client.new
      @elb_client = Aws::ElasticLoadBalancing::Client.new
      @logger = Logger.new(STDOUT)
    end
  end
end
