#!/usr/bin/env ruby
#simple replacement for basic cloud-init features like networking and ssh-key copy
require 'rubygems'
require 'json'
require 'date'
require 'fileutils'

class Ruby_cloud_init
	@@mount 					= '/usr/bin/mount'
	@@umount					= '/usr/bin/umount'
	@@image_path 				= '/dev/disk/by-label/config-2'
	@@mount_path 				= '/tmp'
	@@netconfig_path			= '/etc/sysconfig/network'
	@@ip_bin_path				= '/sbin/ip'
	@@run_file					= 'cloud_init'
	@@run_dir					= '/var/lib/bo'
	@@systemctl 				= '/usr/bin/systemctl'
	@@rand_str 					= [*('A'..'Z')].sample(8).join
	@@config 					= Hash.new
	@@network_config 			= Hash.new
	@@network_config[:ipv4] 	= Hash.new
	@@network_config[:ipv6] 	= Hash.new
	
	def initialize
		check_run
		mount_image
		get_data
		update_network_settings
		write_hosts
		set_hostname
		set_ssh_key unless @@config["public_keys"].nil?
		cleanup
	end

	def check_run
		#checks if cloud_init ran before and quits in case of true
		abort("Ruby_cloud_init ran before, aborting. Delete #{@@run_dir}/#{@@run_file} if you want to run Ruby_cloud_init again") if File.exists?("#{@@run_dir}/#{@@run_file}")
	end

	def cleanup
		umount_res = `#{@@umount} #{@@mount_path}/#{@@rand_str}`
		abort("Error while unmounting #{umount_res}") unless umount_res.empty?
		Dir.delete("#{@@mount_path}/#{@@rand_str}")
		FileUtils.mkdir_p("#{@@run_dir}")
		File.write("#{@@run_dir}/#{@@run_file}", 'true')
		`#{@@systemctl} restart network.service`
	end

	def mount_image
		Dir.mkdir("#{@@mount_path}/#{@@rand_str}")
		mount_res = `#{@@mount} #{@@image_path} #{@@mount_path}/#{@@rand_str}`
		if !mount_res.empty?
			self.cleanup
			abort("Error while mounting") 
		end
	end

	def get_data
		@@config = JSON.parse(File.read("#{@@mount_path}/#{@@rand_str}/openstack/latest/meta_data.json"))
	end

	def update_network_settings
		self.parse_network_file("#{@@mount_path}/#{@@rand_str}/openstack/#{@@config["network_config"]["content_path"]}")
		self.write_network_file
		self.write_route_file
		self.set_routes
		self.print_network_to_stdout
	end

	def parse_network_file(filename)
		file = File.read(filename)
   		self.parseipv4(get_string_between(file, 'iface eth0 inet static', 'iface eth0 inet6 static').strip)
   		self.parseipv6(get_string_between(file, 'iface eth0 inet6 static', /\z/).strip)
	end

	def parseipv4(str)
		@@network_config[:ipv4][:address] 		= get_network_int(str.lines[0])
		@@network_config[:ipv4][:netmask] 		= get_network_int(str.lines[1])
		@@network_config[:ipv4][:broadcast] 	= get_network_int(str.lines[2])
		@@network_config[:ipv4][:gateway] 		= get_network_int(str.lines[3])
		@@network_config[:ipv4][:dns] 			= get_network_int(str.lines[5])
	end
	def parseipv6(str)
		@@network_config[:ipv6][:address] 		= get_network_int(str.lines[0])
		@@network_config[:ipv6][:netmask] 		= get_network_int(str.lines[1])
		@@network_config[:ipv6][:gateway] 		= get_network_int(str.lines[2])
	end

	def write_network_file
		File.write("#{@@netconfig_path}/ifcfg-eth0", "### Berlinonline - Cloudimage
##{DateTime.now.strftime('%a %d %b %Y %H:%M')}
#device: eth0
BOOTPROTO='static'
MTU=''
STARTMODE='auto'
UNIQUE=''
USERCONTROL='no'
IPADDR='#{@@network_config[:ipv4][:address]}/32'
NETMASK='255.255.255.255'
BROADCAST='#{@@network_config[:ipv4][:broadcast]}'
REMOTE_IPADDR='#{@@network_config[:ipv4][:gateway]}'
GATEWAY='#{@@network_config[:ipv4][:gateway]}'
IPADDR_0='#{@@network_config[:ipv6][:address]}/#{@@network_config[:ipv6][:netmask]}'
GATEWAY_0='#{@@network_config[:ipv6][:gateway]}'
#NETMASK_0=''\n"
)
	end

	def print_network_to_stdout
		puts "Deployed following config #{DateTime.now.strftime('%a %d %b %Y %H:%M')}
IPPADDRESS_4=#{@@network_config[:ipv4][:address]}
NETMASK_4=#{@@network_config[:ipv4][:netmask]}
GATEWAY_4=#{@@network_config[:ipv4][:gateway]}
IPPADDRESS_6=#{@@network_config[:ipv6][:address]}
NETMASK_6=#{@@network_config[:ipv6][:netmask]}
"
	end

	def set_routes
		`#{@@ip_bin_path} route add default via #{@@network_config[:ipv4][:gateway]} dev eth0`
		`#{@@ip_bin_path} -6 route add default via #{@@network_config[:ipv6][:gateway]} dev eth0`
	end

	def write_route_file
		File.write("#{@@netconfig_path}/ifroute-eth0", "### Berlinonline - Cloudimage
##{DateTime.now.strftime('%a %d %b %Y %H:%M')}
default #{@@network_config[:ipv4][:gateway]} dev eth0")
	end

	def write_hosts
		File.write("/etc/hosts", "### Berlinonline - Cloudimage
##{DateTime.now.strftime('%a %d %b %Y %H:%M')}
127.0.0.1 		localhost\n
#{@@network_config[:ipv4][:address]}		#{@@config['hostname']} #{@@config['hostname'].split('.').first}
#{@@network_config[:ipv6][:address]}	#{@@config['hostname']} #{@@config['hostname'].split('.').first}\n
::1             ip6-localhost ip6-loopback
fe00::0         ip6-localnet
ff00::0         ip6-mcastprefix
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
ff02::3         ip6-allhosts")
	end

	def set_hostname
		File.write("/etc/HOSTNAME", "#{@@config['hostname'].split('.').first}")
	end

	def set_ssh_key
		#extracting ssh keys from unknown name hash
		keys = Array.new
		Dir.mkdir('/root/.ssh') unless File.directory?('/root/.ssh')
		@@config['public_keys'].each do |f| 
			keys.push(f[1])
		end
		File.write("/root/.ssh/authorized_keys", keys.join)
	end

	def get_string_between(my_string, start_at, end_at)
    	my_string = " #{my_string}"
    	ini = my_string.index(start_at)
    	return my_string if ini == 0
    	ini += start_at.length
    	length = my_string.index(end_at, ini).to_i - ini
   	 	my_string[ini,length]
   	 end

   	 def get_network_int(line)
   	 	line.split(" ")[1]
   	 end
end

run = Ruby_cloud_init.new