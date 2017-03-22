require 'aws-sdk'
require 'ipaddress'
require 'open-uri'
require "logger"
require 'hashie/mash'
require 'net/ping'

class Ec2exMash < Hashie::Mash
  disable_warnings if respond_to?(:disable_warnings)
end

module Ec2ex
  class Core
    def initialize
      ENV['AWS_REGION'] = ENV['AWS_REGION'] || get_document['region']
      @ec2 = Aws::EC2::Client.new
      @elb = Aws::ElasticLoadBalancing::Client.new
      @logger = Logger.new(STDOUT);
    end

    def client
      @ec2
    end

    def logger
      @logger
    end

    def get_document
      JSON.parse(get_metadata('/latest/dynamic/instance-identity/document/'))
    end

    def get_metadata(path)
      begin
        result = {}
        ::Timeout.timeout(TIME_OUT) {
          body = open('http://169.254.169.254' + path).read
          return body
        }
        return result
      rescue Timeout::Error => e
        raise "not EC2 instance"
      end
    end

    def elb_client
      @elb
    end

    def extract_fields(data, fields)
      results = []
      data.each do |row|
        row = Ec2exMash.new(row) if row.class == Hash
        result = {}
        fields.map { |key|
          result[key] = eval("row.#{key}")
        }
        results << result
      end
      results
    end

    def group_count(list)
      Hash[list.group_by { |e| e }.map { |k, v| [k, v.length] }]
    end

    def instances_hash(condition, running_only = true)
      filter = []
      condition.each do |key, value|
        filter << { name: "tag:#{key}", values: ["#{value}"] }
      end
      if running_only
        filter << { name: 'instance-state-name', values: ['running'] }
      else
        filter << { name: 'instance-state-name', values: %w(running stopped) }
      end
      @ec2.describe_instances(
        filters: filter
      ).data.to_h[:reservations].map { |instance| Ec2exMash.new(instance[:instances].first) }
    end

    def instances_hash_first_result(condition, running_only = true)
      results = instances_hash(condition, running_only)
      instance = results.first
      unless instance
        @logger.warn("not match instance => #{condition}")
        exit 1
      end
      instance
    end

    def instances_hash_with_id(instance_id)
      @ec2.describe_instances(
        instance_ids: [instance_id]
      ).data.to_h[:reservations].map { |instance| Ec2exMash.new(instance[:instances].first) }.first
    end

    def wait_spot_running(spot_instance_request_id)
      @logger.info "spot instance creating..."
      instance_id = nil
      while true
        spot_instance_request = @ec2.describe_spot_instance_requests(spot_instance_request_ids: [spot_instance_request_id]).spot_instance_requests.first
        if spot_instance_request.state == 'active'
          instance_id = spot_instance_request.instance_id
          break
        elsif spot_instance_request.state == 'failed'
          @logger.info spot_instance_request.fault.code
          @ec2.cancel_spot_instance_requests({ spot_instance_request_ids: [spot_instance_request_id] })
          raise spot_instance_request.fault.message
        end
        sleep 10
      end
      @ec2.wait_until(:instance_running, instance_ids: [instance_id]) do |w|
        w.interval = 15
        w.max_attempts = 1440
      end

      @logger.info "spot instance create complete! instance_id => [#{instance_id}]"
      instance_id
    end

    def wait_instance_status_ok(instance_id)
      @logger.info "waiting instance status ok... instance_id => [#{instance_id}]"
      while true
        res = @ec2.describe_instance_status(instance_ids: [instance_id])
        instance_status = res.instance_statuses.first.instance_status.status
        if instance_status == 'ok'
          break
        end
        sleep 10
      end
      @logger.info "ready instance! instance_id => [#{instance_id}]"
    end

    def set_delete_on_termination(instance)
      block_device_mappings = instance.block_device_mappings.map{ |block_device_mapping|
        ebs = block_device_mapping.ebs
        {
          device_name: block_device_mapping.device_name,
          ebs: { volume_id: block_device_mapping.ebs.volume_id, delete_on_termination: true }
        }
      }
      @ec2.modify_instance_attribute({instance_id: instance.instance_id, block_device_mappings: block_device_mappings})
    end

    def get_allocation(public_ip_address)
      @ec2.describe_addresses(public_ips: [public_ip_address]).addresses.first
    end

    def get_subnet(private_ip_address)
      subnets = @ec2.describe_subnets.subnets.select{ |subnet|
        ip = IPAddress(subnet.cidr_block)
        ip.to_a.map { |ipv4| ipv4.address }.include?(private_ip_address)
      }
      subnets.first
    end

    def stop_instance(instance_id)
      @logger.info 'stopping...'
      @ec2.stop_instances(
        instance_ids: [instance_id],
        force: true
      )
      @ec2.wait_until(:instance_stopped, instance_ids: [instance_id])
      @logger.info "stop instance complete! instance_id => [#{instance_id}]"
    end

    def start_instance(instance_id)
      @logger.info 'starting...'
      @ec2.start_instances(
        instance_ids: [instance_id]
      )
      @ec2.wait_until(:instance_running, instance_ids: [instance_id])
      @logger.info "start instance complete! instance_id => [#{instance_id}]"
    end

    def terminate_instance(instance)
      instance_id = instance.instance_id
      @logger.info 'terminating...'
      @ec2.terminate_instances(instance_ids: [instance_id])
      @ec2.wait_until(:instance_terminated, instance_ids: [instance_id])
      @logger.info "terminate instance complete! instance_id => [#{instance_id}]"
    end

    def associate_address(instance_id, public_ip_address)
      unless public_ip_address.nil?
        allocation_id = get_allocation(public_ip_address).allocation_id
        resp = @ec2.associate_address(instance_id: instance_id, allocation_id: allocation_id)
      end
    end

    def ping?(private_ip_address)
      if private_ip_address
        pinger = Net::Ping::External.new(private_ip_address)
        if pinger.ping?
          @logger.info "already exists private_ip_address => #{private_ip_address}"
          return true
        end
      end
      return false
    end

    def allocate_address_vpc
      @ec2.allocate_address(domain: 'vpc').data
    end
  end
end
