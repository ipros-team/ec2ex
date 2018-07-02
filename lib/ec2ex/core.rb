require 'aws-sdk'
require "logger"

module Ec2ex
  class Core
    attr_reader :client
    attr_reader :elb_client
    attr_reader :logger

    def initialize(profile = nil)
      begin
        @client = Aws::EC2::Client.new(profile: profile)
      rescue Aws::Errors::MissingRegionError => e
        @client = Aws::EC2::Client.new(region: Metadata.get_document['region'])
      end
      @elb_client = Aws::ElasticLoadBalancing::Client.new
      @logger = Logger.new(STDOUT)
    end
  end
end
