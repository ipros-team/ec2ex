module Ec2ex
  class Util
    class << self
      def extract_fields(data, fields)
        results = []
        data.each do |row|
          row = ::Ec2ex::Mash.new(row) if row.class == Hash
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
    end
  end
end
