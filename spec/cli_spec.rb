require 'spec_helper'
require 'ec2ex'

describe Ec2ex::CLI do
  before do
  end

  it "should stdout sample" do
    output = capture_stdout do
      Ec2ex::CLI.start(['sample'])
    end
    output.should == "This is your new task\n"
  end

  after do
  end
end
