require 'thor'
require 'json'
require 'pp'
require 'hashie'
require 'parallel'
require 'active_support/core_ext/hash'

module Ec2ex
  class CLI < Thor
    include Thor::Actions
    map '-s' => :search
    map '-t' => :search_by_tags
    map '-i' => :search_images
    map '-a' => :aggregate

    class_option :profile, type: :string, default: 'default', required: true, desc: 'name tag'
    class_option :fields, type: :array, default: nil, desc: 'fields'
    def initialize(args = [], options = {}, config = {})
      super(args, options, config)
      @global_options = config[:shell].base.options
      @core = Core.new
      @ec2 = @core.client
      @elb = @core.elb_client
    end

    desc 'search', 'search instance'
    option :name, aliases: '-n', type: :string, default: '', required: true, desc: 'name tag'
    option :running_only, aliases: '--ro', type: :boolean, default: true, desc: 'grouping key'
    def search(name = options['name'])
      results = @core.instances_hash({ Name: name }, options['running_only'])
      puts_json results
    end

    desc 'search_by_tags', 'search by tags instance'
    option :condition, aliases: '-c', type: :hash, default: {}, desc: 'grouping key'
    option :running_only, aliases: '--ro', type: :boolean, default: true, desc: 'grouping key'
    def search_by_tags
      puts_json @core.instances_hash(options['condition'], options['running_only'])
    end

    desc 'reserved', 'reserved instance'
    def reserved
      filter = []
      filter << { name: 'state', values: ['active'] }
      reserved_hash = {}
      @ec2.describe_reserved_instances(filters: filter)[:reserved_instances].each{ |reserved|
        sum = reserved_hash[reserved[:instance_type] + '_' + reserved[:availability_zone]] || 0
        reserved_hash[reserved[:instance_type] + '_' + reserved[:availability_zone]] = sum + reserved[:instance_count]
      }
      list = @core.instances_hash({}, true).select { |instance| instance[:instance_lifecycle].nil? }
      list = list.map{ |_instance|
        ['instance_type', 'placement.availability_zone'].map do |key|
          eval("_instance.#{key} ")
        end.join('_')
      }
      result = {}
      @core.group_count(list).each do |k, v|
        result[k] = { instance_count: v, reserved_count: 0 }
      end
      reserved_hash.each do |k, v|
        hash = result[k] || { instance_count: 0 }
        hash[:reserved_count] = v
        result[k] = hash
      end
      puts_json(result)
    end

    desc 'create_image', 'create image'
    option :name, aliases: '-n', type: :string, required: true, desc: 'name tag'
    option :proc, type: :numeric, default: Parallel.processor_count, desc: 'Number of parallel'
    def create_image
      results = @core.instances_hash({ Name: options['name'] }, false)
      Parallel.map(results, in_threads: options['proc']) do |instance|
        begin
          @core.create_image_with_instance(instance)
        rescue => e
          puts "\n#{e.message}\n#{e.backtrace.join("\n")}"
        end
      end
    end

    desc 'deregister_image', 'deregister image'
    option :name, aliases: '-n', type: :string, default: '', required: true, desc: 'name tag'
    option :older_than, aliases: '--older_than', type: :numeric, default: 30, desc: 'older than count.'
    def deregister_image
      @core.get_old_images(options['name'], options['older_than']).each do |image|
        image_id = image[:image_id]
        puts "delete AMI #{image_id}"
        @ec2.deregister_image({image_id: image_id})
        snapshot_ids = image[:block_device_mappings]
            .select{ |block_device_mapping| block_device_mapping[:ebs] != nil }
            .map{ |block_device_mapping| block_device_mapping[:ebs][:snapshot_id] }

        snapshot_ids.each do |snapshot_id|
          puts "delete snapshot #{snapshot_id}"
          @ec2.delete_snapshot({snapshot_id: snapshot_id})
        end
      end
    end

    desc 'deregister_image', 'deregister image'
    option :name, aliases: '-n', type: :string, default: '', required: true, desc: 'name tag'
    option :older_than, aliases: '--older_than', type: :numeric, default: 30, desc: 'older than count.'
    def old_images
      puts_json(@core.get_old_images(options['name'], options['older_than']))
    end

    desc 'deregister_snapshot_no_related', 'AMI not related snapshot basis delete all'
    option :owner_id, type: :string, required: true, desc: 'owner_id'
    def deregister_snapshot_no_related
      @core.deregister_snapshot_no_related(options['owner_id'])
    end

    desc 'copy', 'copy instance'
    option :name, aliases: '-n', type: :string, default: '', required: true, desc: 'name tag'
    option :params, aliases: '-p', type: :string, default: '{}', desc: 'params'
    option :tag, aliases: '-t', type: :hash, default: {}, desc: 'name tag'
    def copy
      results = @core.instances_hash({ Name: options['name'] }, true)
      results.each do |instance|
        image_id = @core.create_image_with_instance(instance)
        security_group_ids = instance.security_groups.map { |security_group| security_group.group_id }
        request = {
          image_id: image_id,
          min_count: 1,
          max_count: 1,
          security_group_ids: security_group_ids,
          instance_type: instance.instance_type,
          placement: instance.placement.to_hash,
          subnet_id: instance.subnet_id,
          private_ip_address: instance.private_ip_address
        }
        unless instance.iam_instance_profile.nil?
          request[:iam_instance_profile] = { name: instance.iam_instance_profile.arn.split('/').last }
        end
        if instance.key_name
          request[:key_name] = instance.key_name
        end

        request.merge!(eval(options['params']))
        request[:subnet_id] = @core.get_subnet(request[:private_ip_address]).subnet_id

        response = @ec2.run_instances(request)
        instance_id = response.instances.first.instance_id
        @ec2.wait_until(:instance_running, instance_ids: [instance_id])
        @ec2.create_tags(resources: [instance_id], tags: instance.tags)
        unless options['tag'].nil?
          @ec2.create_tags(resources: [instance_id], tags: @core.format_tag(options['tag']))
        end
      end
    end

    desc 'renew', 'renew instance'
    option :name, aliases: '-n', type: :string, default: '', required: true, desc: 'name tag'
    option :stop, type: :boolean, default: true, desc: 'stop'
    option :params, aliases: '-p', type: :string, default: nil, desc: 'params'
    def renew
      params = eval(options['params'])
      results = @core.instances_hash({ Name: options['name'] }, false)
      results.each do |instance|
        tags = instance.tags
        tag_hash = @core.get_tag_hash(tags)
        if options['stop']
          @core.stop_instance(instance.instance_id)
        end

        image_id = @core.create_image_with_instance(instance)

        @core.terminate_instance(instance)
        security_group_ids = instance.security_groups.map { |security_group| security_group.group_id }
        request = {
          image_id: image_id,
          min_count: 1,
          max_count: 1,
          security_group_ids: security_group_ids,
          instance_type: instance.instance_type,
          placement: instance.placement.to_hash,
          private_ip_address: instance.private_ip_address
        }
        unless instance.iam_instance_profile.nil?
          request[:iam_instance_profile] = { name: instance.iam_instance_profile.arn.split('/').last }
        end
        request.merge!(params)
        request[:subnet_id] = @core.get_subnet(request[:private_ip_address]).subnet_id

        response = @ec2.run_instances(request)
        instance_id = response.instances.first.instance_id
        sleep 5
        @ec2.wait_until(:instance_running, instance_ids: [instance_id])
        @ec2.create_tags(resources: [instance_id], tags: instance.tags)

        @core.associate_address(instance_id, instance.public_ip_address)
      end
    end

    desc 'spot', 'request spot instances'
    option :name, aliases: '-n', type: :string, required: true, desc: 'name tag'
    option :price, type: :string, required: true, desc: 'price'
    option :private_ip_address, type: :string, default: nil, desc: 'private_ip_address'
    option :public_ip_address, type: :string, default: nil, desc: 'public_ip_address'
    option :block_duration_minutes, type: :numeric, default: nil, desc: 'block_duration_minutes'
    option :params, aliases: '-p', type: :string, default: '{}', desc: 'params'
    option :tag, aliases: '-t', type: :hash, default: {}, desc: 'name tag'
    option :renew, aliases: '-r', type: :boolean, default: false, desc: 'renew instance'
    option :persistent, type: :boolean, default: false, desc: 'persistent request'
    option :stop, type: :boolean, default: false, desc: 'stop'
    def spot
      results = @core.instances_hash({ Name: options['name'] }, true)
      results.each do |instance|
        if options['stop']
          @core.stop_instance(instance.instance_id)
        end
        image_id = @core.create_image_with_instance(instance)

        security_group_ids = instance.security_groups.map { |security_group| security_group.group_id }
        option = {
          instance_count: 1,
          spot_price: options['price'],
          launch_specification: {
            image_id: image_id,
            instance_type: instance.instance_type,
            security_group_ids: security_group_ids,
            subnet_id: instance.subnet_id
          },
        }
        option[:type] = 'persistent' if options['persistent']
        option[:block_duration_minutes] = options['block_duration_minutes'] if options['block_duration_minutes']

        unless instance.iam_instance_profile.nil?
          option[:launch_specification][:iam_instance_profile] = { name: instance.iam_instance_profile.arn.split('/').last }
        end

        unless instance.key_name.nil?
          option[:launch_specification][:key_name] = instance.key_name
        end

        option[:launch_specification].merge!(eval(options['params']))

        private_ip_address = nil
        if options['private_ip_address'].nil?
          private_ip_address = instance.private_ip_address if options['renew']
        else
          private_ip_address = options['private_ip_address']
        end

        unless private_ip_address.nil?
          network_interface = {
            device_index: 0,
            subnet_id: @core.get_subnet(private_ip_address).subnet_id,
            groups: option[:launch_specification][:security_group_ids],
            private_ip_addresses: [{ private_ip_address: private_ip_address, primary: true }]
          }
          option[:launch_specification][:network_interfaces] = [network_interface]
          option[:launch_specification].delete(:security_group_ids)
          option[:launch_specification].delete(:subnet_id)
        end
        @core.terminate_instance(instance) if options['renew']

        response = @ec2.request_spot_instances(option)
        spot_instance_request_id = response.spot_instance_requests.first.spot_instance_request_id
        sleep 5
        instance_id = @core.wait_spot_running(spot_instance_request_id)
        @core.set_delete_on_termination(@core.instances_hash_with_id(instance_id))

        @ec2.create_tags(resources: [instance_id], tags: instance.tags)
        @ec2.create_tags(resources: [instance_id], tags: [{ key: 'Spot', value: 'true' }])

        unless options['tag'].empty?
          @ec2.create_tags(resources: [instance_id], tags: @core.format_tag(options['tag']))
        end

        public_ip_address = nil
        if options['public_ip_address'].nil?
          public_ip_address = instance.public_ip_address if options['renew']
        else
          public_ip_address = options['public_ip_address']
        end
        @core.associate_address(instance_id, public_ip_address)
      end
    end

    desc 'run_spot', 'run_spot latest image'
    option :name, aliases: '-n', type: :string, required: true, desc: 'name tag'
    option :price, type: :string, required: true, desc: 'price'
    option :private_ip_address, type: :string, default: nil, desc: 'private_ip_address'
    option :params, aliases: '-p', type: :string, default: '{}', desc: 'params'
    option :block_duration_minutes, type: :numeric, default: nil, desc: 'block_duration_minutes'
    def run_spot
      private_ip_address = options['private_ip_address']
      image = @core.latest_image_with_name(options['name'])
      tag_hash = @core.get_tag_hash(image[:tags])
      option = {
        instance_count: 1,
        spot_price: options['price'],
        launch_specification: {
          image_id: image[:image_id],
          instance_type: tag_hash.instance_type
        },
      }

      option[:block_duration_minutes] = options['block_duration_minutes'] if options['block_duration_minutes']

      if tag_hash.iam_instance_profile
        option[:launch_specification][:iam_instance_profile] = { name: tag_hash.iam_instance_profile }
      end

      if tag_hash.key_name
        option[:launch_specification][:key_name] = tag_hash.key_name
      end

      network_interface = {
        device_index: 0,
        subnet_id: @core.get_subnet(private_ip_address || tag_hash.private_ip_address).subnet_id,
        groups: JSON.parse(tag_hash.security_groups),
        private_ip_addresses: [{ private_ip_address: private_ip_address || tag_hash.private_ip_address, primary: true }]
      }
      option[:launch_specification][:network_interfaces] = [network_interface]
      option[:launch_specification].merge!(eval(options['params']))

      response = @ec2.request_spot_instances(option)
      spot_instance_request_id = response.spot_instance_requests.first.spot_instance_request_id
      sleep 5
      instance_id = @core.wait_spot_running(spot_instance_request_id)
      @core.set_delete_on_termination(@core.instances_hash_with_id(instance_id))
      @ec2.create_tags(resources: [instance_id], tags: JSON.parse(tag_hash[:tags]))

      if tag_hash.public_ip_address
        @core.associate_address(instance_id, tag_hash.public_ip_address)
      end
    end

    desc 'regist_deny_acl', 'regist deny acl'
    option :acl_id, type: :string, default: '', required: true, desc: 'name tag'
    option :ip_address, type: :string, default: '', required: true, desc: 'name tag'
    def regist_deny_acl
      acls = @ec2.describe_network_acls(network_acl_ids: [options['acl_id']])

      allow_any_rule_number = acls.network_acls.first.entries.select {|r|
                         !r.egress && r.cidr_block == '0.0.0.0/0' && r.rule_action == 'allow'
                       }.first.rule_number

      deny_rules = acls.network_acls.first.entries.select {|r|
                         !r.egress && r.rule_number < allow_any_rule_number
                       }.sort_by { |r| r.rule_number }

      next_rule_number = deny_rules.empty? ? 1 : deny_rules.last.rule_number + 1

      unless deny_rules.any? { |r| r.cidr_block == "#{options['ip_address']}/32" }
        option = {
          network_acl_id: options['acl_id'],
          rule_number: next_rule_number,
          rule_action: 'deny',
          protocol: '-1',
          cidr_block: "#{options['ip_address']}/32",
          egress: false
        }
        @ec2.create_network_acl_entry(option)
      end
    end

    desc 'delete_deny_acl_all', 'delete deny acl'
    option :acl_id, type: :string, required: true, desc: 'name tag'
    def delete_deny_acl_all
      acls = @ec2.describe_network_acls(network_acl_ids: [options['acl_id']])

      allow_any_rule_number = acls.network_acl_set.first.entries.select {|r|
                         !r.egress && r.cidr_block == '0.0.0.0/0' && r.rule_action == 'allow'
                       }.first.rule_number

      deny_rules = acls.network_acls.first.entries.select {|r|
                         !r.egress && r.rule_number < allow_any_rule_number
                       }.sort_by { |r| r.rule_number }

      deny_rules.each do |deny_rule|
        option = {
          network_acl_id: options['acl_id'],
          rule_number: deny_rule.rule_number,
          egress: false
        }
        @ec2.delete_network_acl_entry(option)
      end
    end

    desc 'acls', 'show acls'
    def acls
      puts_json(@ec2.describe_network_acls.data.to_hash[:network_acls])
    end

    desc 'subnets', 'show subnets'
    def subnets
      puts_json(@ec2.describe_subnets.data.to_hash[:subnets])
    end

    desc 'sg', 'show security groups'
    def sg
      puts_json(@ec2.describe_security_groups.data.to_hash[:security_groups])
    end

    desc 'copy_tag', 'request spot instances'
    option :source, aliases: '--src', type: :string, default: nil, required: true, desc: 'name tag'
    option :dest, aliases: '--dest', type: :string, default: nil, required: true, desc: 'name tag'
    def copy_tag(_name = options['name'])
      source = @core.instances_hash({ Name: options['source'] }, true)
      dest = @core.instances_hash({ Name: options['dest'] }, true)
      @ec2.create_tags(resources: dest.map { |instance| instance.instance_id }, tags: source.first.tags)
      @ec2.create_tags(resources: dest.map { |instance| instance.instance_id }, tags: [{ key: 'Name', value: options['dest'] }])
    end

    desc 'set_tag', 'set tag'
    option :name, aliases: '-n', type: :string, required: true, desc: 'name tag'
    option :tag, aliases: '-t', type: :hash, required: true, desc: 'name tag'
    def set_tag
      instances = @core.instances_hash({ Name: options['name'] }, true)
      tags = @core.format_tag(options['tag'])
      @ec2.create_tags(resources: instances.map { |instance| instance.instance_id }, tags: tags)
    end

    desc 'reboot', 'reboot instance'
    option :name, aliases: '-n', type: :string, required: true, desc: 'name tag'
    def set_delete_on_termination
      @core.instances_hash({ Name: options['name'] }, true).each do |instance|
        @core.set_delete_on_termination(instance)
        puts "set delete on termination => #{instance.instance_id}"
      end
    end

    desc 'search_images', 'search images'
    option :name, aliases: '-n', type: :string, default: '', required: true, desc: 'name tag'
    def search_images(name = options['name'])
      puts_json @core.images(name)
    end

    desc 'aggregate', 'say hello to NAME'
    option :condition, aliases: '-c', type: :hash, default: {}, desc: 'grouping key'
    option :key, aliases: '-k', type: :array, required: true, desc: 'grouping key'
    option :running_only, aliases: '--ro', type: :boolean, default: true, desc: 'grouping key'
    def aggregate
      list = @core.instances_hash(options['condition'], options['running_only']).map do |instance|
        options['key'].map do |key|
          eval("instance.#{key} ")
        end.join('_')
      end
      puts @core.group_count(list).to_json
    end

    desc 'reboot', 'reboot instance'
    option :name, aliases: '-n', type: :string, default: '', required: true, desc: 'name tag'
    def reboot
      @core.instances_hash({ Name: options['name'] }, true).each do |instance|
        @ec2.reboot_instances(instance_ids: [instance.instance_id])
        sleep 5
        @ec2.wait_until(:instance_running, instance_ids: [instance.instance_id])
      end
    end

    desc 'stop_start', 'stop after start instance'
    option :names, aliases: '-n', type: :array, default: [], required: true, desc: 'name tag'
    def stop_start
      options['names'].each do |name|
        @core.instances_hash({ Name: name }, true).each do |instance|
          instance.stop
          @ec2.wait_until(:instance_stopped, instance_ids: [instance.instance_id])
          instance.start
          @ec2.wait_until(:instance_running, instance_ids: [instance.instance_id])
          puts "#{instance.tags['Name']} restart complete!"
        end
      end
    end

    desc 'terminate', 'terminate instance'
    option :name, aliases: '-n', type: :string, required: true, desc: 'name tag'
    def terminate
      @core.instances_hash({ Name: options['name'] }, false).each do |instance|
        @core.terminate_instance(instance)
      end
    end

    desc 'start', 'start instance'
    option :name, aliases: '-n', type: :string, required: true, desc: 'name tag'
    def start
      @core.instances_hash({ Name: options['name'] }, false).each do |instance|
        @core.start_instance(instance.instance_id)
      end
    end

    desc 'stop', 'stop instance'
    option :name, aliases: '-n', type: :string, required: true, desc: 'name tag'
    def stop
      @core.instances_hash({ Name: options['name'] }, false).each do |instance|
        @core.stop_instance(instance.instance_id)
      end
    end

    desc 'connect elb', 'connect elb'
    option :name, aliases: '-n', type: :string, default: '', required: true, desc: 'name tag'
    option :load_balancer_name, aliases: '-l', type: :string, default: '', required: true, desc: 'name tag'
    def connect_elb(_name = options['name'])
      @core.instances_hash({ Name: options['name'] }, true).each do |instance|
        option = { load_balancer_name: options['load_balancer_name'], instances: [instance_id: instance.instance_id] }
        @elb.deregister_instances_from_load_balancer(option)
        @elb.register_instances_with_load_balancer(option)
        print 'connecting ELB...'
        loop do
          break if 'InService' == @elb.describe_instance_health(option).instance_states.first.state
          sleep 10
          print '.'
        end
      end
    end

    desc 'disconnect elb', 'disconnect elb'
    option :name, aliases: '-n', type: :string, default: '', required: true, desc: 'name tag'
    option :load_balancer_name, aliases: '-l', type: :string, default: '', required: true, desc: 'name tag'
    def disconnect_elb
      @core.instances_hash({ Name: options['name'] }, true).each do |instance|
        option = { load_balancer_name: options['load_balancer_name'], instances: [instance_id: instance.instance_id] }
        @elb.deregister_instances_from_load_balancer(option)
      end
    end

    desc 'elbs', 'show elbs'
    def elbs
      puts_json @elb.describe_load_balancers.data.to_h[:load_balancer_descriptions]
    end

    desc 'events', 'show events'
    def events
      results = []
      @core.instances_hash({}, true).each do |i|
        status = @ec2.describe_instance_status(instance_ids: [i.instance_id])
        events = status.data[:instance_status_set][0][:events] rescue nil
        next if events.nil? or events.empty?
        events.each do |event|
          next if event[:description] =~ /^\[Completed\]/
          event[:id] = i.id
          event[:name] = i.tags['Name']
          event[:availability_zone] = i.availability_zone
          results << event
        end
      end
      puts_json results
    end

    desc 'latest_image', 'show elbs'
    option :name, aliases: '-n', type: :string, required: true, desc: 'name tag'
    def latest_image
      puts_json @core.latest_image_with_name(options['name'])
    end

    desc 'allocate_address', 'allocate address'
    def allocate_address
      response = @ec2.allocate_address(domain: 'vpc')
      puts response
    end

    private
    def instances(name, _running_only = true)
      @ec2.instances.with_tag('Name', "#{name}")
    end

    def puts_json(data)
      unless @global_options['fields'].nil?
        data = @core.extract_fields(data, @global_options['fields'])
      end
      puts JSON.pretty_generate(data)
    end
  end
end
