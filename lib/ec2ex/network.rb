require 'ipaddress'
require 'net/ping'

module Ec2ex
  class Network
    def initialize(core)
      @core = core
    end

    def get_allocation(public_ip_address)
      @core.client.describe_addresses(public_ips: [public_ip_address]).addresses.first
    end

    def get_subnet(private_ip_address)
      subnets = @core.client.describe_subnets.subnets.select{ |subnet|
        ip = IPAddress(subnet.cidr_block)
        ip.to_a.map { |ipv4| ipv4.address }.include?(private_ip_address)
      }
      subnets.first
    end

    def associate_address(instance_id, public_ip_address)
      unless public_ip_address.nil?
        allocation_id = get_allocation(public_ip_address).allocation_id
        resp = @core.client.associate_address(instance_id: instance_id, allocation_id: allocation_id)
      end
    end

    def ping?(private_ip_address)
      if private_ip_address
        pinger = Net::Ping::External.new(private_ip_address)
        if pinger.ping?
          @core.logger.info "already exists private_ip_address => #{private_ip_address}"
          return true
        end
      end
      return false
    end

    def allocate_address_vpc
      @core.client.allocate_address(domain: 'vpc').data
    end
  end
end
