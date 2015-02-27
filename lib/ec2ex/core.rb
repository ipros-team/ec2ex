require 'aws-sdk'
require 'ipaddress'
require 'open-uri'

TIME_OUT = 3
module Ec2ex
  class Core
    def initialize
      ENV['AWS_REGION'] = ENV['AWS_REGION'] || get_metadata['region']
      @ec2 = Aws::EC2::Client.new
      @elb = Aws::ElasticLoadBalancing::Client.new
    end

    def client
      @ec2
    end

    def get_metadata
      begin
        result = {}
        timeout(TIME_OUT) {
          body = open('http://169.254.169.254/latest/dynamic/instance-identity/document/').read
          result = JSON.parse(body)
        }
        return result
      rescue TimeoutError => e
        raise "not EC2 instance"
      end
    end

    def elb_client
      @elb
    end

    def extract_fields(data, fields)
      results = []
      data.each do |row|
        row = Hashie::Mash.new(row) if row.class == Hash
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

    def format_tag(tag)
      tags = []
      tag.each do |k, v|
        tags << { key: k, value: v || '' }
      end
      tags
    end

    def get_tag_hash(tags)
      result = {}
      tags.each {|hash|
        result[hash['key'] || hash[:key]] = hash['value'] || hash[:value]
      }
      Hashie::Mash.new(result)
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
      ).data.to_h[:reservations].map { |instance| Hashie::Mash.new(instance[:instances].first) }
    end

    def images(name)
      filter = [{ name: 'is-public', values: ['false'] }]
      filter << { name: 'name', values: ["#{name}"] }
      @ec2.describe_images(
        filters: filter
      ).data.to_h[:images]
    end

    def create_image_with_instance(instance)
      tags = get_tag_hash(instance.tags)
      puts "#{tags['Name']} image creating..."
      snapshot = {
        'created' => Time.now.strftime('%Y%m%d%H%M%S'),
        'tags' => instance.tags.map(&:to_hash).to_json,
        'Name' => tags['Name']
      }
      snapshot['security_groups'] = instance.security_groups.map(&:group_id).to_json
      snapshot['private_ip_address'] = instance.private_ip_address
      unless instance.public_ip_address.nil?
        snapshot['public_ip_address'] = instance.public_ip_address
      end
      snapshot['instance_type'] = instance.instance_type
      snapshot['placement'] = instance.placement.to_hash.to_json
      unless instance.iam_instance_profile.nil?
        snapshot['iam_instance_profile'] = instance.iam_instance_profile.arn.split('/').last
      end

      image_response = @ec2.create_image(
        instance_id: instance.instance_id,
        name: tags['Name'] + ".#{Time.now.strftime('%Y%m%d%H%M%S')}",
        no_reboot: true
      )
      sleep 10
      @ec2.wait_until(:image_available, image_ids: [image_response.image_id]) do |w|
        w.interval = 15
        w.max_attempts = 720
      end
      puts "image create complete! image_id => [#{image_response.image_id}]"

      ami_tag = format_tag(snapshot)
      @ec2.create_tags(resources: [image_response.image_id], tags: ami_tag)
      image_response.image_id
    end

    def wait_spot_running(spot_instance_request_id)
      puts 'spot instance creating...'
      instance_id = nil
      while true
        spot_instance_request = @ec2.describe_spot_instance_requests(spot_instance_request_ids: [spot_instance_request_id]).spot_instance_requests.first
        if spot_instance_request.state == 'active'
          instance_id = spot_instance_request.instance_id
          break
        end
        sleep 10
      end
      @ec2.wait_until(:instance_running, instance_ids: [instance_id])
      puts "spot instance create complete! instance_id => [#{instance_id}]"
      instance_id
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
      puts 'stopping...'
      @ec2.stop_instances(
        instance_ids: [instance_id],
        force: true
      )
      @ec2.wait_until(:instance_stopped, instance_ids: [instance_id])
      puts "stop instance complete! instance_id => [#{instance_id}]"
    end

    def start_instance(instance_id)
      puts 'starting...'
      @ec2.start_instances(
        instance_ids: [instance_id]
      )
      @ec2.wait_until(:instance_running, instance_ids: [instance_id])
      puts "start instance complete! instance_id => [#{instance_id}]"
    end

    def terminate_instance(instance_id)
      puts 'terminating...'
      @ec2.terminate_instances(instance_ids: [instance_id])
      @ec2.wait_until(:instance_terminated, instance_ids: [instance_id])
      puts "terminate instance complete! instance_id => [#{instance_id}]"
    end

    def associate_address(instance_id, public_ip_address)
      unless public_ip_address.nil?
        allocation_id = get_allocation(public_ip_address).allocation_id
        resp = @ec2.associate_address(instance_id: instance_id, allocation_id: allocation_id)
      end
    end

    def latest_image_with_name(name)
      filter = [{ name: 'is-public', values: ['false'] }]
      filter << { name: 'tag:Name', values: [name] }
      result = @ec2.describe_images(
        filters: filter
      ).data.to_h[:images]
      result = result.sort_by{ |image|
        tag_hash = get_tag_hash(image[:tags])
        tag_hash['created'].nil? ? '' : tag_hash['created']
      }
      result.empty? ? {} : result.last
    end
  end
end
