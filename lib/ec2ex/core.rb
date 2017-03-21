require 'aws-sdk'
require 'ipaddress'
require 'open-uri'
require "logger"
require 'hashie/mash'
require 'net/ping'

class Ec2exMash < Hashie::Mash
  disable_warnings if respond_to?(:disable_warnings)
end

TIME_OUT = 3
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

    def format_tag(tag, preset_tag_hash = {})
      tags = []
      tag.each do |k, v|
        value = v ? ERB.new(v.gsub(/\$\{([^}]+)\}/, "<%=preset_tag_hash['" + '\1' + "'] %>")).result(binding) : ''
        tags << { key: k, value: value }
      end
      tags
    end

    def get_tag_hash(tags)
      result = {}
      tags.each {|hash|
        result[hash['key'] || hash[:key]] = hash['value'] || hash[:value]
      }
      Ec2exMash.new(result)
    end

    def get_tag_hash_from_id(instance_id)
      preset_tag = {}
      @ec2.describe_tags(filters: [{ name: 'resource-id', values: [instance_id] }]).tags.each do |tag|
        preset_tag[tag.key] = tag.value
      end
      preset_tag
    end

    def own_tag
      get_tag_hash(instances_hash_with_id(get_metadata('/latest/meta-data/instance-id')).tags)
    end

    def get_ami_tag_hash(instance, tags)
      ami_tag_hash = {
        'created' => Time.now.strftime('%Y%m%d%H%M%S'),
        'tags' => tags.to_json,
        'Name' => tags['Name']
      }
      ami_tag_hash['security_groups'] = instance.security_groups.map(&:group_id).to_json
      ami_tag_hash['private_ip_address'] = instance.private_ip_address
      unless instance.public_ip_address.nil?
        ami_tag_hash['public_ip_address'] = instance.public_ip_address
      end
      ami_tag_hash['instance_type'] = instance.instance_type
      ami_tag_hash['placement'] = instance.placement.to_hash.to_json
      unless instance.iam_instance_profile.nil?
        ami_tag_hash['iam_instance_profile'] = instance.iam_instance_profile.arn.split('/').last
      end
      unless instance.key_name.nil?
        ami_tag_hash['key_name'] = instance.key_name
      end
      ami_tag_hash
    end

    def create_image_with_instance(instance, region = nil)
      tags = get_tag_hash(instance.tags)
      @logger.info "#{tags['Name']} image creating..."

      image_name = tags['Name'] + ".#{Time.now.strftime('%Y%m%d%H%M%S')}"
      image_response = @ec2.create_image(
        instance_id: instance.instance_id,
        name: image_name,
        no_reboot: true
      )
      sleep 10
      @ec2.wait_until(:image_available, image_ids: [image_response.image_id]) do |w|
        w.interval = 15
        w.max_attempts = 1440
      end
      @logger.info "image create complete #{tags['Name']}! image_id => [#{image_response.image_id}]"

      ami_tag = format_tag(get_ami_tag_hash(instance, tags))
      @ec2.create_tags(resources: [image_response.image_id], tags: ami_tag)

      if region
        @logger.info "copying another region... [#{ENV['AWS_REGION']}] => [#{region}]"
        dest_ec2 = Aws::EC2::Client.new(region: region)
        copy_image_response = dest_ec2.copy_image(
          source_region: ENV['AWS_REGION'],
          source_image_id: image_response.image_id,
          name: image_name
        )
        dest_ec2.create_tags(resources: [copy_image_response.image_id], tags: ami_tag)
      end

      image_response.image_id
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

    def latest_image_with_name(name)
      result = search_image_with_name(name)
      result = result.sort_by{ |image|
        tag_hash = get_tag_hash(image[:tags])
        tag_hash['created'].nil? ? '' : tag_hash['created']
      }
      result.empty? ? {} : result.last
    end

    def get_old_images(name, num = 10)
      result = search_image_with_name(name)
      return [] if result.empty?
      map = Hash.new{|h,k| h[k] = []}
      result = result.each{ |image|
        tag_hash = get_tag_hash(image[:tags])
        next if tag_hash['Name'].nil? || tag_hash['created'].nil?
        map[tag_hash['Name']] << image
      }
      old_images = []
      map.each do |name, images|
        sorted_images = images.sort_by{ |image|
          tag_hash = get_tag_hash(image[:tags])
          Time.parse(tag_hash['created'])
        }
        newly_images = sorted_images.last(num)
        old_images = old_images + (sorted_images - newly_images)
      end
      old_images
    end

    def images(name)
      filter = [{ name: 'is-public', values: ['false'] }]
      filter << { name: 'name', values: [name] }
      @ec2.describe_images(
        filters: filter
      ).data.to_h[:images]
    end

    def search_image_with_name(name)
      filter = [{ name: 'is-public', values: ['false'] }]
      filter << { name: 'tag:Name', values: [name] }
      @ec2.describe_images(
        filters: filter
      ).data.to_h[:images]
    end

    def deregister_snapshot_no_related(owner_id)
      enable_snapshot_ids = []
      images('*').each do |image|
        image_id = image[:image_id]
        snapshot_ids = image[:block_device_mappings]
          .select{ |block_device_mapping| block_device_mapping[:ebs] != nil }
          .map{ |block_device_mapping| block_device_mapping[:ebs][:snapshot_id] }
        enable_snapshot_ids.concat(snapshot_ids)
      end
      filter = [{ name: 'owner-id', values: [owner_id] }]
      all_snapshot_ids = @ec2.describe_snapshots(
        filters: filter
      ).data.to_h[:snapshots].map{ |snapshot| snapshot[:snapshot_id] }
      disable_snapshot_ids = (all_snapshot_ids - enable_snapshot_ids)
      disable_snapshot_ids.each do |disable_snapshot_id|
        @ec2.delete_snapshot({snapshot_id: disable_snapshot_id})
        @logger.info "delete snapshot #{disable_snapshot_id}"
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
