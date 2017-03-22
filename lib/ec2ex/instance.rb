module Ec2ex
  class Instance < Base

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
      @core.client.describe_instances(
        filters: filter
      ).data.to_h[:reservations].map { |instance| ::Ec2ex::Mash.new(instance[:instances].first) }
    end

    def instances_hash_first_result(condition, running_only = true)
      results = instances_hash(condition, running_only)
      instance = results.first
      unless instance
        @core.logger.warn("not match instance => #{condition}")
        exit 1
      end
      instance
    end

    def instances_hash_with_id(instance_id)
      @core.client.describe_instances(
        instance_ids: [instance_id]
      ).data.to_h[:reservations].map { |instance| ::Ec2ex::Mash.new(instance[:instances].first) }.first
    end

    def wait_spot_running(spot_instance_request_id)
      @core.logger.info "spot instance creating..."
      instance_id = nil
      while true
        spot_instance_request = @core.client.describe_spot_instance_requests(spot_instance_request_ids: [spot_instance_request_id]).spot_instance_requests.first
        if spot_instance_request.state == 'active'
          instance_id = spot_instance_request.instance_id
          break
        elsif spot_instance_request.state == 'failed'
          @core.logger.info spot_instance_request.fault.code
          @core.client.cancel_spot_instance_requests({ spot_instance_request_ids: [spot_instance_request_id] })
          raise spot_instance_request.fault.message
        end
        sleep 10
      end
      @core.client.wait_until(:instance_running, instance_ids: [instance_id]) do |w|
        w.interval = 15
        w.max_attempts = 1440
      end

      @core.logger.info "spot instance create complete! instance_id => [#{instance_id}]"
      instance_id
    end

    def wait_instance_status_ok(instance_id)
      @core.logger.info "waiting instance status ok... instance_id => [#{instance_id}]"
      while true
        res = @core.client.describe_instance_status(instance_ids: [instance_id])
        instance_status = res.instance_statuses.first.instance_status.status
        if instance_status == 'ok'
          break
        end
        sleep 10
      end
      @core.logger.info "ready instance! instance_id => [#{instance_id}]"
    end

    def set_delete_on_termination(instance)
      block_device_mappings = instance.block_device_mappings.map{ |block_device_mapping|
        ebs = block_device_mapping.ebs
        {
          device_name: block_device_mapping.device_name,
          ebs: { volume_id: block_device_mapping.ebs.volume_id, delete_on_termination: true }
        }
      }
      @core.client.modify_instance_attribute({instance_id: instance.instance_id, block_device_mappings: block_device_mappings})
    end

    def stop_instance(instance_id)
      @core.logger.info 'stopping...'
      @core.client.stop_instances(
        instance_ids: [instance_id],
        force: true
      )
      @core.client.wait_until(:instance_stopped, instance_ids: [instance_id])
      @core.logger.info "stop instance complete! instance_id => [#{instance_id}]"
    end

    def start_instance(instance_id)
      @core.logger.info 'starting...'
      @core.client.start_instances(
        instance_ids: [instance_id]
      )
      @core.client.wait_until(:instance_running, instance_ids: [instance_id])
      @core.logger.info "start instance complete! instance_id => [#{instance_id}]"
    end

    def terminate_instance(instance)
      instance_id = instance.instance_id
      @core.logger.info 'terminating...'
      @core.client.terminate_instances(instance_ids: [instance_id])
      @core.client.wait_until(:instance_terminated, instance_ids: [instance_id])
      @core.logger.info "terminate instance complete! instance_id => [#{instance_id}]"
    end

    def reserved
      filter = []
      filter << { name: 'state', values: ['active'] }
      reserved_hash = {}
      @core.client.describe_reserved_instances(filters: filter)[:reserved_instances].each{ |reserved|
        key = "#{reserved[:instance_type]}_#{reserved[:availability_zone]}"
        sum = reserved_hash[key] || 0
        reserved_hash[key] = sum + reserved[:instance_count]
      }
      list = instances_hash({}, true).select { |instance| instance[:instance_lifecycle].nil? }
      list = list.map{ |_instance|
        ['instance_type', 'placement.availability_zone'].map do |key|
          eval("_instance.#{key} ")
        end.join('_')
      }
      result = {}
      Util.group_count(list).each do |k, v|
        result[k] = { instance_count: v, reserved_count: 0 }
      end
      reserved_hash.each do |k, v|
        hash = result[k] || { instance_count: 0 }
        hash[:reserved_count] = v
        result[k] = hash
      end
      result
    end
  end
end
