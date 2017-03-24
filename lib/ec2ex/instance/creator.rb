module Ec2ex
  class Instance
    class Creator < Base

      def initialize(core)
        super
        @tag = Tag.new(core)
        @ami = Ami.new(core)
        @network = Network.new(core)
        @instance = Instance.new(core)
      end

      def run_spot(options)
        image = @ami.latest_image_with_name(options[:name])

        tag_hash = Tag.get_hash(image[:tags])
        instance_count = options[:instance_count]

        private_ip_address = options[:private_ip_address] || tag_hash.private_ip_address
        subnet_id = @network.get_subnet(private_ip_address).subnet_id
        if instance_count == 1
          exit 0 if @network.ping?(private_ip_address)
        else
          private_ip_address = nil
        end

        in_threads = (instance_count > 20) ? 20 : instance_count

        Parallel.map(instance_count.times.to_a, in_threads: in_threads) do |server_index|
          option = {
            instance_count: 1,
            spot_price: options[:price],
            launch_specification: {
              image_id: image[:image_id],
              instance_type: tag_hash.instance_type
            },
          }

          option[:block_duration_minutes] = options[:block_duration_minutes] if options[:block_duration_minutes]

          if private_ip_address
            network_interface = {
              device_index: 0,
              subnet_id: subnet_id,
              groups: JSON.parse(tag_hash.security_groups),
              private_ip_addresses: [{ private_ip_address: private_ip_address, primary: true }]
            }
            option[:launch_specification][:network_interfaces] = [network_interface]
          else
            option[:launch_specification][:security_group_ids] = JSON.parse(tag_hash.security_groups)
            option[:launch_specification][:subnet_id] = subnet_id
          end

          if tag_hash.iam_instance_profile
            option[:launch_specification][:iam_instance_profile] = { name: tag_hash.iam_instance_profile }
          end

          if tag_hash.key_name
            option[:launch_specification][:key_name] = tag_hash.key_name
          end

          option[:launch_specification].merge!(eval(options[:params]))

          response = @core.client.request_spot_instances(option)
          spot_instance_request_id = response.spot_instance_requests.first.spot_instance_request_id
          sleep 5
          instance_id = @instance.wait_spot_running(spot_instance_request_id)
          @instance.set_delete_on_termination(@instance.instances_hash_with_id(instance_id))
          @core.client.create_tags(
            resources: [instance_id],
            tags: Tag.format(JSON.parse(tag_hash.tags))
          )
          @core.client.create_tags(resources: [instance_id], tags: [{ key: 'InstanceIndex', value: "#{server_index}" }])
          @core.client.create_tags(resources: [instance_id], tags: [{ key: 'InstanceCount', value: "#{instance_count}" }])

          unless options[:tag].empty?
            @core.client.create_tags(
              resources: [instance_id],
              tags: Tag.format(
                options[:tag],
                @tag.get_hash_from_id(instance_id)
              )
            )
          end

          if tag_hash.public_ip_address
            @network.associate_address(instance_id, tag_hash.public_ip_address)
          end
        end
      end

      def copy(options)
        instance = @instance.instances_hash_first_result({ Name: options[:name] }, true)
        image_id = options[:image_id] || @ami.create_image_with_instance(instance)

        instance_count = options[:instance_count]
        in_threads = (instance_count > 20) ? 20 : instance_count

        groups = instance_count.times.to_a.each_slice(in_threads).to_a
        groups.each do |group|
          is_last = (groups.last == group)
          Parallel.map(group, in_threads: in_threads) do |server_index|
            security_group_ids = instance.security_groups.map { |security_group| security_group.group_id }
            request = {
              image_id: image_id,
              min_count: 1,
              max_count: 1,
              security_group_ids: security_group_ids,
              instance_type: instance.instance_type,
              placement: instance.placement.to_hash
            }
            request[:private_ip_address] = options[:private_ip_address] if options[:private_ip_address]
            if instance.iam_instance_profile
              request[:iam_instance_profile] = { name: instance.iam_instance_profile.arn.split('/').last }
            end
            if instance.key_name
              request[:key_name] = instance.key_name
            end

            request.merge!(eval(options[:params]))
            request[:subnet_id] = if request[:private_ip_address]
              @network.get_subnet(request[:private_ip_address]).subnet_id
            else
              instance.subnet_id
            end

            response = @core.client.run_instances(request)
            instance_id = response.instances.first.instance_id
            @core.client.wait_until(:instance_running, instance_ids: [instance_id])
            @core.client.create_tags(resources: [instance_id], tags: instance.tags)
            @core.client.create_tags(resources: [instance_id], tags: [{ key: 'InstanceIndex', value: "#{server_index}" }])
            @core.client.create_tags(resources: [instance_id], tags: [{ key: 'InstanceCount', value: "#{instance_count}" }])
            unless options[:tag].nil?
              @core.client.create_tags(
                resources: [instance_id],
                tags: Tag.format(
                  options[:tag],
                  @tag.get_hash_from_id(instance_id)
                )
              )
            end
            @instance.wait_instance_status_ok(instance_id) if is_last

            public_ip_address = @network.get_public_ip_address(options[:public_ip_address], instance.public_ip_address, false)
            @network.associate_address(instance_id, public_ip_address)
            @core.logger.info("created instance => #{instance_id}")
          end
        end
      end

      def spot(options)
        instance = @instance.instances_hash_first_result({ Name: options[:name] }, true)
        if options[:stop]
          @instance.stop_instance(instance.instance_id)
        end

        instance_count = options[:instance_count]
        in_threads = (instance_count > 20) ? 20 : instance_count

        image_id = options[:image_id] || @ami.create_image_with_instance(instance)

        groups = instance_count.times.to_a.each_slice(in_threads).to_a
        groups.each do |group|
          is_last = (groups.last == group)
          Parallel.map(group, in_threads: in_threads) do |server_index|
            security_group_ids = instance.security_groups.map { |security_group| security_group.group_id }
            option = {
              instance_count: 1,
              spot_price: options[:price],
              launch_specification: {
                image_id: image_id,
                instance_type: instance.instance_type
              }
            }
            option[:type] = 'persistent' if options[:persistent]
            option[:block_duration_minutes] = options[:block_duration_minutes] if options[:block_duration_minutes]

            if instance.iam_instance_profile
              option[:launch_specification][:iam_instance_profile] = { name: instance.iam_instance_profile.arn.split('/').last }
            end

            if instance.key_name
              option[:launch_specification][:key_name] = instance.key_name
            end

            private_ip_address = nil
            if options[:private_ip_address].nil?
              private_ip_address = instance.private_ip_address if options[:renew]
            else
              private_ip_address = options[:private_ip_address]
            end

            if private_ip_address
              network_interface = {
                device_index: 0,
                subnet_id: @network.get_subnet(private_ip_address).subnet_id,
                groups: security_group_ids,
                private_ip_addresses: [{ private_ip_address: private_ip_address, primary: true }]
              }
              option[:launch_specification][:network_interfaces] = [network_interface]
            else
              option[:launch_specification][:security_group_ids] = security_group_ids
              option[:launch_specification][:subnet_id] = instance.subnet_id
            end
            option[:launch_specification].merge!(eval(options[:params]))
            @instance.terminate_instance(instance) if options[:renew]

            response = @core.client.request_spot_instances(option)
            spot_instance_request_id = response.spot_instance_requests.first.spot_instance_request_id
            sleep 5
            instance_id = @instance.wait_spot_running(spot_instance_request_id)
            @instance.set_delete_on_termination(@instance.instances_hash_with_id(instance_id))

            @core.client.create_tags(resources: [instance_id], tags: instance.tags)
            @core.client.create_tags(resources: [instance_id], tags: [{ key: 'Spot', value: 'true' }])
            @core.client.create_tags(resources: [instance_id], tags: [{ key: 'InstanceIndex', value: "#{server_index}" }])
            @core.client.create_tags(resources: [instance_id], tags: [{ key: 'InstanceCount', value: "#{instance_count}" }])

            unless options[:tag].empty?
              @core.client.create_tags(
                resources: [instance_id],
                tags: Tag.format(
                  options[:tag],
                  @tag.get_hash_from_id(instance_id)
                )
              )
            end

            @instance.wait_instance_status_ok(instance_id) if is_last

            public_ip_address = @network.get_public_ip_address(options[:public_ip_address], instance.public_ip_address, options[:renew])
            @network.associate_address(instance_id, public_ip_address)
          end
        end
      end

      def renew(options)
        params = eval(options[:params])
        results = @instance.instances_hash({ Name: options[:name] }, false)
        results.each do |instance|
          tags = instance.tags
          tag_hash = Tag.get_hash(tags)
          if options[:stop]
            @instance.stop_instance(instance.instance_id)
          end

          image_id = @ami.create_image_with_instance(instance)

          @instance.terminate_instance(instance)
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
          if instance.iam_instance_profile
            request[:iam_instance_profile] = { name: instance.iam_instance_profile.arn.split('/').last }
          end

          if instance.key_name
            request[:key_name] = instance.key_name
          end
          request.merge!(params)
          request[:subnet_id] = @network.get_subnet(request[:private_ip_address]).subnet_id

          response = @core.client.run_instances(request)
          instance_id = response.instances.first.instance_id
          sleep 5
          @core.client.wait_until(:instance_running, instance_ids: [instance_id])
          @core.client.create_tags(resources: [instance_id], tags: instance.tags)

          @network.associate_address(instance_id, instance.public_ip_address)
        end
      end
    end
  end
end
