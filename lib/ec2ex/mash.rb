require 'hashie/mash'

module Ec2ex
  class Mash < Hashie::Mash
    disable_warnings if respond_to?(:disable_warnings)
  end
end
