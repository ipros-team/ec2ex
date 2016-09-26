# ec2ex [![Build Status](https://secure.travis-ci.org/toyama0919/ec2ex.png?branch=master)](http://travis-ci.org/toyama0919/ec2ex)

## Examples

### Search Instance

```
$ ec2ex -s 'stgweb01'
```

### Copy Instance

```
$ ec2ex copy -n "stgembulk01" -t Name:stgembulk02 --public_ip_address auto --instance_count 3
```

### Copy Spot Instance

```
$ ec2ex spot -n "web01" --price 0.5 --private_ip_address 10.0.0.100 -t Name:web02
```

### Deployment Instance

```
$ ec2ex run_spot -n "stgembulk01" --price 0.5
```

### Connect ELB Instance

```
$ ec2ex connect_elb -n "web01" -l elbname
```

### Disconnect ELB Instance

```
$ ec2ex disconnect_elb -n "web02" -l elbname
```

### Terminate Instance

```
$ ec2ex terminate -n web01
```

### Renew Instance

```
$ ec2ex renew -n "presto01" --private-ip-address 10.0.81.201 -p '{iam_instance_profile: { name: "iap-role"} }'
```

### Create AMI with tag

```
$ ec2 create_image -n "presto01"
```


## Installation

Add this line to your application's Gemfile:

    gem 'ec2ex', github: 'ipros-team/ec2ex'

And then execute:

    $ bundle

Or install it yourself as:

    $ gem specific_install -l https://github.com/ipros-team/ec2ex

## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new [Pull Request](../../pull/new/master)

## Information

* [Homepage](https://github.com/toyama0919/ec2ex)
* [Issues](https://github.com/toyama0919/ec2ex/issues)
* [Documentation](http://rubydoc.info/gems/ec2ex/frames)
* [Email](mailto:toyama0919@gmail.com)

## Copyright

Copyright (c) 2014 Hiroshi Toyama

See [LICENSE.txt](../LICENSE.txt) for details.
