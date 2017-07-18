require 'thor'
require 'json'
require 'pp'
require 'parallel'
require 'active_support/core_ext/hash'
require 'terminal-table'

module Ec2ex
  class CLI < Thor
    include Thor::Actions
    map '-s' => :search
    map '--st' => :search_by_tags
    map '-i' => :search_images
    map '-a' => :aggregate

    class_option :fields, type: :array, default: nil, desc: 'fields'
    def initialize(args = [], options = {}, config = {})
      super(args, options, config)
      @global_options = config[:shell].base.options
      @core = Core.new

      @tag = Tag.new(@core)
      @ami = Ami.new(@core)
      @network = Network.new(@core)
      @instance = Instance.new(@core)
      @creator = Instance::Creator.new(@core)
      @alb = Alb.new(@core)
    end

    desc 'search', 'search instance'
    option :name, aliases: '-n', type: :string, default: '', required: true, desc: 'name tag'
    option :running_only, aliases: '--ro', type: :boolean, default: true, desc: 'search running only instances.'
    option :output_format, aliases: '--of', type: :string, default: 'table', enum: ['table', 'json'], desc: 'output format'
    def search(name = options[:name])
      results = @instance.instances_hash({ Name: name }, options[:running_only])
      if options[:output_format] == 'json'
        puts_json results
      elsif options[:output_format] == 'table'
        puts_table results
      end
    end

    desc 'search_by_tags', 'search by tags instance'
    option :tag, aliases: '-t', type: :hash, default: {}, desc: 'exp. Stages:production'
    option :running_only, aliases: '--ro', type: :boolean, default: true, desc: 'search running only instances.'
    def search_by_tags
      puts_json @instance.instances_hash(options[:tag], options[:running_only])
    end

    desc 'reserved', 'reserved instance'
    def reserved
      puts_json(@instance.reserved)
    end

    desc 'create_image', 'create image'
    option :name, aliases: '-n', type: :string, required: true, desc: 'name tag'
    option :proc, type: :numeric, default: Parallel.processor_count, desc: 'Number of parallel'
    option :region, aliases: '-r', type: :string, required: false, default: nil, desc: 'region'
    def create_image
      results = @instance.instances_hash({ Name: options[:name] }, false)
      Parallel.map(results, in_threads: options[:proc]) do |instance|
        begin
          @ami.create_image_with_instance(instance, options[:region])
        rescue => e
          @core.logger.info "\n#{e.message}\n#{e.backtrace.join("\n")}"
        end
      end
    end

    desc 'deregister_image', 'deregister image'
    option :name, aliases: '-n', type: :string, default: '', required: true, desc: 'name tag'
    option :ami_name, type: :string, desc: 'ami_name'
    option :older_than, aliases: '--older_than', type: :numeric, default: 30, desc: 'older than count.'
    def deregister_image
      @ami.deregister_image(ami_name: options[:ami_name], name: options[:name], older_than: options[:older_than])
    end

    desc 'deregister_image', 'deregister image'
    option :name, aliases: '-n', type: :string, default: '', required: true, desc: 'name tag'
    option :older_than, aliases: '--older_than', type: :numeric, default: 30, desc: 'older than count.'
    def old_images
      puts_json(@ami.get_old_images(options[:name], options[:older_than]))
    end

    desc 'deregister_snapshot_no_related', 'AMI not related snapshot basis delete all'
    option :owner_id, type: :string, required: true, desc: 'owner_id'
    def deregister_snapshot_no_related
      @ami.deregister_snapshot_no_related(options[:owner_id])
    end

    desc 'copy', 'copy instance'
    option :name, aliases: '-n', type: :string, default: '', required: true, desc: 'name tag'
    option :params, aliases: '-p', type: :string, default: '{}', desc: 'params'
    option :tag, aliases: '-t', type: :hash, default: {}, desc: 'name tag'
    option :private_ip_address, type: :string, default: nil, desc: 'private_ip_address'
    option :public_ip_address, type: :string, default: nil, desc: 'public_ip_address'
    option :instance_count, type: :numeric, default: 1, desc: 'instance_count'
    option :image_id, aliases: '-i', type: :string, desc: 'AMI image_id'
    def copy
      @creator.copy(options)
    end

    desc 'renew', 'renew instance'
    option :name, aliases: '-n', type: :string, default: '', required: true, desc: 'name tag'
    option :stop, type: :boolean, default: true, desc: 'stop'
    option :params, aliases: '-p', type: :string, default: '{}', desc: 'params'
    def renew
      @creator.renew(options)
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
    option :instance_count, type: :numeric, default: 1, desc: 'instance_count'
    option :image_id, aliases: '-i', type: :string, desc: 'AMI image_id'
    option :instance_types, type: :array, default: [], desc: 'instance types'
    def spot
      @creator.spot(options)
    end

    desc 'run_spot', 'run_spot latest image'
    option :name, aliases: '-n', type: :string, required: true, desc: 'name tag'
    option :price, type: :string, required: true, desc: 'price'
    option :private_ip_address, type: :string, default: nil, desc: 'private_ip_address'
    option :params, aliases: '-p', type: :string, default: '{}', desc: 'params'
    option :block_duration_minutes, type: :numeric, default: nil, desc: 'block_duration_minutes'
    option :instance_count, type: :numeric, default: 1, desc: 'instance_count'
    option :tag, aliases: '-t', type: :hash, default: {}, desc: 'tag'
    option :instance_types, type: :array, default: [], desc: 'instance types'
    option :image_id, aliases: '-i', type: :string, desc: 'AMI image_id'
    def run_spot
      @creator.run_spot(options)
    end

    desc 'regist_deny_acl', 'regist deny acl'
    option :acl_id, type: :string, default: '', required: true, desc: 'name tag'
    option :ip_address, type: :string, default: '', required: true, desc: 'name tag'
    def regist_deny_acl
      acls = @core.client.describe_network_acls(network_acl_ids: [options[:acl_id]])

      allow_any_rule_number = acls.network_acls.first.entries.select {|r|
                         !r.egress && r.cidr_block == '0.0.0.0/0' && r.rule_action == 'allow'
                       }.first.rule_number

      deny_rules = acls.network_acls.first.entries.select {|r|
                         !r.egress && r.rule_number < allow_any_rule_number
                       }.sort_by { |r| r.rule_number }

      next_rule_number = deny_rules.empty? ? 1 : deny_rules.last.rule_number + 1

      unless deny_rules.any? { |r| r.cidr_block == "#{options[:ip_address]}/32" }
        option = {
          network_acl_id: options[:acl_id],
          rule_number: next_rule_number,
          rule_action: 'deny',
          protocol: '-1',
          cidr_block: "#{options[:ip_address]}/32",
          egress: false
        }
        @core.client.create_network_acl_entry(option)
      end
    end

    desc 'delete_deny_acl_all', 'delete deny acl'
    option :acl_id, type: :string, required: true, desc: 'name tag'
    def delete_deny_acl_all
      acls = @core.client.describe_network_acls(network_acl_ids: [options[:acl_id]])

      allow_any_rule_number = acls.network_acl_set.first.entries.select {|r|
                         !r.egress && r.cidr_block == '0.0.0.0/0' && r.rule_action == 'allow'
                       }.first.rule_number

      deny_rules = acls.network_acls.first.entries.select {|r|
                         !r.egress && r.rule_number < allow_any_rule_number
                       }.sort_by { |r| r.rule_number }

      deny_rules.each do |deny_rule|
        option = {
          network_acl_id: options[:acl_id],
          rule_number: deny_rule.rule_number,
          egress: false
        }
        @core.client.delete_network_acl_entry(option)
      end
    end

    desc 'acls', 'show acls'
    def acls
      puts_json(@core.client.describe_network_acls.data.to_hash[:network_acls])
    end

    desc 'subnets', 'show subnets'
    def subnets
      puts_json(@core.client.describe_subnets.data.to_hash[:subnets])
    end

    desc 'sg', 'show security groups'
    def sg
      puts_json(@core.client.describe_security_groups.data.to_hash[:security_groups])
    end

    desc 'copy_tag', 'request spot instances'
    option :source, aliases: '--src', type: :string, default: nil, required: true, desc: 'name tag'
    option :dest, aliases: '--dest', type: :string, default: nil, required: true, desc: 'name tag'
    option :resource, aliases: '-r', type: :string, default: 'instance', enum: ['instance', 'ami'], desc: 'resource'
    def copy_tag
      source_tags = if options[:resource] == 'instance'
        instance = @instance.instances_hash({ Name: options[:source] }, true).first
        instance.tags
      elsif options[:resource] == 'ami'
        @ami.search_images(options[:source]).first[:tags]
      end

      dest_id = if options[:resource] == 'instance'
        @instance.instances_hash({ Name: options[:dest] }, true).first.instance_id
      elsif options[:resource] == 'ami'
        @ami.search_images(options[:dest]).first[:image_id]
      end

      @core.client.create_tags(resources: [dest_id], tags: source_tags)
      if options[:resource] == 'instance'
        @core.client.create_tags(resources: [dest_id], tags: [{ key: 'Name', value: options[:dest] }])
      end
    end

    desc 'set_tag', 'set tag'
    option :name, aliases: '-n', type: :string, required: true, desc: 'name tag'
    option :tag, aliases: '-t', type: :hash, required: true, desc: 'name tag'
    option :resource, aliases: '-r', type: :string, default: 'instance', enum: ['instance', 'ami'], desc: 'resource'
    def set_tag
      ids = if options[:resource] == 'instance'
        @instance.instances_hash({ Name: options[:name] }, true).map {  |instance| instance.instance_id }
      elsif options[:resource] == 'ami'
        @ami.search_images(options[:name]).map { |image| image[:image_id] }
      end

      tags = Tag.format(options[:tag])
      @core.client.create_tags(resources: ids, tags: tags)
    end

    desc 'set_delete_on_termination', 'set delete on termination instance'
    option :name, aliases: '-n', type: :string, required: true, desc: 'name tag'
    def set_delete_on_termination
      @instance.instances_hash({ Name: options[:name] }, true).each do |instance|
        @instance.set_delete_on_termination(instance)
        @core.logger.info "set delete on termination => #{instance.instance_id}"
      end
    end

    desc 'search_images', 'search images'
    option :name, aliases: '-n', type: :string, default: '', required: true, desc: 'name tag'
    def search_images(name = options[:name])
      puts_json @ami.search_images(name)
    end

    desc 'aggregate', 'aggregate'
    option :condition, aliases: '-c', type: :hash, default: {}, desc: 'grouping key'
    option :key, aliases: '-k', type: :array, required: true, desc: 'grouping key'
    option :running_only, aliases: '--ro', type: :boolean, default: true, desc: 'grouping key'
    def aggregate
      list = @instance.instances_hash(options[:condition], options[:running_only]).map do |instance|
        options[:key].map do |key|
          eval("instance.#{key} ")
        end.join('_')
      end
      puts Util.group_count(list).to_json
    end

    desc 'reboot', 'reboot instance'
    option :name, aliases: '-n', type: :string, default: '', required: true, desc: 'name tag'
    def reboot
      @instance.instances_hash({ Name: options[:name] }, true).each do |instance|
        @core.client.reboot_instances(instance_ids: [instance.instance_id])
        sleep 5
        @core.client.wait_until(:instance_running, instance_ids: [instance.instance_id])
      end
    end

    desc 'stop_start', 'stop after start instance'
    option :names, aliases: '-n', type: :array, default: [], required: true, desc: 'name tag'
    def stop_start
      options[:names].each do |name|
        @instance.instances_hash({ Name: name }, true).each do |instance|
          instance.stop
          @core.client.wait_until(:instance_stopped, instance_ids: [instance.instance_id])
          instance.start
          @core.client.wait_until(:instance_running, instance_ids: [instance.instance_id])
          @core.logger.info "#{instance.tags['Name']} restart complete!"
        end
      end
    end

    desc 'terminate', 'terminate instance'
    option :name, aliases: '-n', type: :string, required: true, desc: 'name tag'
    def terminate
      instances = @instance.instances_hash({ Name: options[:name] }, false)
      Parallel.map(instances, in_threads: instances.size) do |instance|
        @instance.terminate_instance(instance)
      end
    end

    desc 'start', 'start instance'
    option :name, aliases: '-n', type: :string, required: true, desc: 'name tag'
    def start
      @instance.instances_hash({ Name: options[:name] }, false).each do |instance|
        @instance.start_instance(instance.instance_id)
      end
    end

    desc 'stop', 'stop instance'
    option :name, aliases: '-n', type: :string, required: true, desc: 'name tag'
    def stop
      @instance.instances_hash({ Name: options[:name] }, false).each do |instance|
        @instance.stop_instance(instance.instance_id)
      end
    end

    desc 'connect alb', 'connect alb'
    option :name, aliases: '-n', type: :string, default: '', required: true, desc: 'name tag'
    option :target_group_name, aliases: '-t', type: :string, default: '', required: true, desc: 'target group name'
    def connect_alb
      @alb.connect(options)
    end

    desc 'connect elb', 'connect elb'
    option :name, aliases: '-n', type: :string, default: '', required: true, desc: 'name tag'
    option :load_balancer_name, aliases: '-l', type: :string, default: '', required: true, desc: 'name tag'
    def connect_elb(_name = options[:name])
      @instance.instances_hash({ Name: options[:name] }, true).each do |instance|
        option = { load_balancer_name: options[:load_balancer_name], instances: [instance_id: instance.instance_id] }
        @core.elb_client.deregister_instances_from_load_balancer(option)
        @core.elb_client.register_instances_with_load_balancer(option)
        print 'connecting ELB...'
        loop do
          break if 'InService' == @core.elb_client.describe_instance_health(option).instance_states.first.state
          sleep 10
          print '.'
        end
      end
    end

    desc 'disconnect elb', 'disconnect elb'
    option :name, aliases: '-n', type: :string, default: '', required: true, desc: 'name tag'
    option :load_balancer_name, aliases: '-l', type: :string, default: '', required: true, desc: 'name tag'
    def disconnect_elb
      @instance.instances_hash({ Name: options[:name] }, true).each do |instance|
        option = { load_balancer_name: options[:load_balancer_name], instances: [instance_id: instance.instance_id] }
        @core.elb_client.deregister_instances_from_load_balancer(option)
      end
    end

    desc 'elbs', 'show elbs'
    def elbs
      puts_json @core.elb_client.describe_load_balancers.data.to_h[:load_balancer_descriptions]
    end

    desc 'events', 'show events'
    def events
      results = []
      @instance.instances_hash({}, true).each do |i|
        status = @core.client.describe_instance_status(instance_ids: [i.instance_id])
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
      puts_json @ami.latest_image_with_name(options[:name])
    end

    desc 'allocate_address', 'allocate address'
    def allocate_address_vpc
      response = @network.allocate_address_vpc
      puts response.data
    end

    desc 'instance_metadata', 'instance metadata'
    option :path, type: :string, required: true, desc: 'path'
    def instance_metadata
      response = Metadata.get_metadata(options[:path])
      puts response
    end

    desc 'own_tag', 'own tag'
    option :key, type: :string, desc: 'key'
    def own_tag
      response = @tag.get_own
      if options[:key]
        puts response[options[:key]]
      else
        puts_json response
      end
    end

    desc 'price', 'price'
    option :instance_types, required: true, type: :array, desc: 'instance types'
    option :availability_zone, required: true, type: :string, desc: 'availability zone'
    def spot_price_history
      puts_json(
        @instance.spot_price_history_latest(
          instance_types: options[:instance_types],
          availability_zone: options[:availability_zone]
        )
      )
    end

    private
    def instances(name, _running_only = true)
      @core.client.instances.with_tag('Name', "#{name}")
    end

    def puts_json(data)
      unless @global_options[:fields].nil?
        data = Util.extract_fields(data, @global_options[:fields])
      end
      puts JSON.pretty_generate(data)
    end

    def puts_table(data)
      headings = {
        "instance_id" => 'instance_id',
        "state" => 'state.name',
        "Name" => 'tags.select{|tag| tag["key"] == "Name" }.first["value"]',
        "instance_type" => 'instance_type',
        "private_ip_address" => 'private_ip_address',
        "availability_zone" => 'placement.availability_zone',
        "instance_lifecycle" => 'instance_lifecycle'
      }
      rows = data.map do |row|
        headings.values.map { |heading| eval("row.#{heading}") }
      end
      puts Terminal::Table.new :headings => headings.keys, :rows => rows
    end
  end
end
