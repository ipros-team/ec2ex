module Ec2ex
  class Base
    attr_reader :core

    def initialize(core)
      @core = core
    end
  end
end
