module Ec2ex
  class Ami
    def initialize(core)
      @core = core
    end

    def create_image_with_instance(instance, region = nil)
      tags = Tag.get_hash(instance.tags)
      @core.logger.info "#{tags['Name']} image creating..."

      image_name = tags['Name'] + ".#{Time.now.strftime('%Y%m%d%H%M%S')}"
      image_response = @core.client.create_image(
        instance_id: instance.instance_id,
        name: image_name,
        no_reboot: true
      )
      sleep 10
      @core.client.wait_until(:image_available, image_ids: [image_response.image_id]) do |w|
        w.interval = 15
        w.max_attempts = 1440
      end
      @core.logger.info "image create complete #{tags['Name']}! image_id => [#{image_response.image_id}]"

      ami_tag = Tag.format(Tag.get_ami_tag_hash(instance, tags))
      @core.client.create_tags(resources: [image_response.image_id], tags: ami_tag)

      if region
        @core.logger.info "copying another region... [#{ENV['AWS_REGION']}] => [#{region}]"
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

    def latest_image_with_name(name)
      result = search_image_with_name(name)
      result = result.sort_by{ |image|
        tag_hash = Tag.get_hash(image[:tags])
        tag_hash['created'].nil? ? '' : tag_hash['created']
      }
      result.empty? ? {} : result.last
    end

    def get_old_images(name, num = 10)
      result = search_image_with_name(name)
      return [] if result.empty?
      map = Hash.new{|h,k| h[k] = []}
      result = result.each{ |image|
        tag_hash = Tag.get_hash(image[:tags])
        next if tag_hash['Name'].nil? || tag_hash['created'].nil?
        map[tag_hash['Name']] << image
      }
      old_images = []
      map.each do |name, images|
        sorted_images = images.sort_by{ |image|
          tag_hash = Tag.get_hash(image[:tags])
          Time.parse(tag_hash['created'])
        }
        newly_images = sorted_images.last(num)
        old_images = old_images + (sorted_images - newly_images)
      end
      old_images
    end

    def search_images(name)
      filter = [{ name: 'is-public', values: ['false'] }]
      filter << { name: 'name', values: [name] }
      @core.client.describe_images(
        filters: filter
      ).data.to_h[:images]
    end

    def search_image_with_name(name)
      filter = [{ name: 'is-public', values: ['false'] }]
      filter << { name: 'tag:Name', values: [name] }
      @core.client.describe_images(
        filters: filter
      ).data.to_h[:images]
    end

    def deregister_snapshot_no_related(owner_id)
      enable_snapshot_ids = []
      search_images('*').each do |image|
        image_id = image[:image_id]
        snapshot_ids = image[:block_device_mappings]
          .select{ |block_device_mapping| block_device_mapping[:ebs] != nil }
          .map{ |block_device_mapping| block_device_mapping[:ebs][:snapshot_id] }
        enable_snapshot_ids.concat(snapshot_ids)
      end
      filter = [{ name: 'owner-id', values: [owner_id] }]
      all_snapshot_ids = @core.client.describe_snapshots(
        filters: filter
      ).data.to_h[:snapshots].map{ |snapshot| snapshot[:snapshot_id] }
      disable_snapshot_ids = (all_snapshot_ids - enable_snapshot_ids)
      disable_snapshot_ids.each do |disable_snapshot_id|
        @core.client.delete_snapshot({snapshot_id: disable_snapshot_id})
        @core.logger.info "delete snapshot #{disable_snapshot_id}"
      end
    end
  end
end
