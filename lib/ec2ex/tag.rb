module Ec2ex
  class Tag
    class << self
      def format(tag, preset_tag_hash = {})
        tags = []
        tag.each do |k, v|
          value = v ? ERB.new(v.gsub(/\$\{([^}]+)\}/, "<%=preset_tag_hash['" + '\1' + "'] %>")).result(binding) : ''
          tags << { key: k, value: value }
        end
        tags
      end

      def get_hash(tags)
        result = {}
        tags.each {|hash|
          result[hash['key'] || hash[:key]] = hash['value'] || hash[:value]
        }
        Ec2exMash.new(result)
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
    end

    def initialize(core)
      @core = core
    end

    def get_hash_from_id(instance_id)
      preset_tag = {}
      @core.client.describe_tags(filters: [{ name: 'resource-id', values: [instance_id] }]).tags.each do |tag|
        preset_tag[tag.key] = tag.value
      end
      preset_tag
    end

    def get_own
      self.class.get_hash(
        @core.instances_hash_with_id(@core.get_metadata('/latest/meta-data/instance-id')).tags
      )
    end
  end
end
