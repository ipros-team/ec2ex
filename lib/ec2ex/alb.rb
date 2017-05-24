module Ec2ex
  class Alb
    def initialize(core)
      @core = core
      @alb_client = Aws::ElasticLoadBalancingV2::Client.new
      @instance = Instance.new(core)
    end

    def connect(options)
      resp = @alb_client.describe_target_groups({ names: [options[:target_group_name]] })
      target_group_arn = resp.target_groups.first.target_group_arn
      @instance.instances_hash({ Name: options[:name] }, true).each do |instance|
        print "connecting #{options[:name]} to #{options[:target_group_name]}"
        @alb_client.register_targets({
          target_group_arn: target_group_arn,
          targets: [{ id: instance['instance_id'] }]
        })
        loop do
          target_health = @alb_client.describe_target_health({
            target_group_arn: target_group_arn,
            targets: [{ id: instance['instance_id'] }]
          })
          break if 'healthy' == target_health.target_health_descriptions.first.target_health.state
          sleep 10
          print '.'
        end
      end
    end
  end
end
