require 'chef/provider/lwrp_base'
require_relative 'helpers'

class Chef
  class Provider
    class UcNext < Chef::Provider::LWRPBase # rubocop:disable ClassLength
      # Chef 11 LWRP DSL Methods
      use_inline_resources if defined?(use_inline_resources)

      def whyrun_supported?
        true
      end

      # Mix in helpers from libraries/helpers.rb
      include UcNextCookbook::Helpers

      action :create do
        # user
        group "#{new_resource.name} :create ucnext" do
          append true
          group_name new_resource.run_group
          action :create
        end

        user "#{new_resource.name} :create ucnext" do
          username new_resource.run_user
          gid 'ucnext' if new_resource.run_user == 'ucnext'
          action :create
        end
        # init file for service, abstract to support deb and rhel7
        template "/etc/init.d/ucnext-#{new_resource.name}" do
          owner 'root'
          group 'root'
          mode '0755'
          source 'sysvinit.erb'
          cookbook 'ucnext'
          variables(config: new_resource)
        end

        template "/etc/ImageMagick/policy.xml" do
          owner 'root'
          group 'root'
          mode '0755'
          source 'image-magick-policy.xml.erb'
          cookbook 'ucnext'
          variables(config: new_resource)
        end

        # add shared dirs for chef deploy
        directory "#{new_resource.deploy_path}/shared" do
          recursive true
          owner new_resource.run_user
          group new_resource.run_group
        end

        %w(config pids log uploads).each do |d|
          directory "#{new_resource.deploy_path}/shared/#{d}" do
            recursive true
            owner new_resource.run_user
            group new_resource.run_group
          end
        end

        # database.yml
        template "#{new_resource.deploy_path}/shared/config/database.yml" do
          source 'database.yml.erb'
          cookbook 'ucnext'
          owner new_resource.run_user
          group new_resource.run_group
          variables(config: new_resource)
          notifies :restart, "service[ucnext-#{new_resource.name}]", :delayed
        end

        # secrets
        template "#{new_resource.deploy_path}/shared/config/secrets.yml" do
          source 'secrets.yml.erb'
          cookbook 'ucnext'
          owner new_resource.run_user
          group new_resource.run_group
          variables(config: new_resource)
          notifies :restart, "service[ucnext-#{new_resource.name}]", :delayed
        end

        # generate ES config file, only supports one instance currently.
        template "#{new_resource.deploy_path}/shared/config/elasticsearch.yml" do
          source 'elasticsearch.yml.erb'
          cookbook 'ucnext'
          owner new_resource.run_user
          group new_resource.run_group
          variables(config: new_resource)
          notifies :restart, "service[ucnext-#{new_resource.name}]", :delayed
        end

        template "#{new_resource.deploy_path}/shared/config/auth.yml" do
          source 'auth.yml.erb'
          cookbook 'ucnext'
          owner new_resource.run_user
          group new_resource.run_group
          variables(config: new_resource)
          notifies :restart, "service[ucnext-#{new_resource.name}]", :delayed
        end

        template "#{new_resource.deploy_path}/shared/config/smtp.yml" do
          source 'smtp.yml.erb'
          cookbook 'ucnext'
          owner new_resource.run_user
          group new_resource.run_group
          variables(config: new_resource)
          notifies :restart, "service[ucnext-#{new_resource.name}]", :delayed
        end

        # required headers for mysql2, imagemagick gem (which gets installed with bundler below)
        # not OS compatible yet, refactor
        %w(mysql-devel ImageMagick ImageMagick-devel sqlite sqlite-devel).each do |pkg|
          package pkg
        end

        # farm out to chef deploy.
        # note namespace "new resource" causes some weird stuff here.
        computed_path = path_plus_bundler
        ucnext_resource = new_resource
        deploy_branch ucnext_resource.name do
          deploy_to ucnext_resource.deploy_path
          repo ucnext_resource.repo
          revision ucnext_resource.revision
          user ucnext_resource.run_user
          group ucnext_resource.run_group
          symlink_before_migrate(
            'config/auth.yml' => 'config/auth.yml',
            'config/database.yml' => 'config/database.yml',
            'config/elasticsearch.yml' => 'config/elasticsearch.yml',
            'config/secrets.yml' => 'config/secrets.yml',
            'config/smtp.yml' => 'config/smtp.yml',
            'uploads' => 'public/',
            'bundle' => '.bundle'
          )
          before_migrate do
            execute 'bundle install' do
              environment 'PATH' => computed_path
              cwd release_path
              command "bundle install --path #{ucnext_resource.deploy_path}/shared/bundle"
            end
            execute 'npm install' do
              cwd release_path
            end
            execute 'block build' do
              environment 'PATH' => computed_path
              cwd release_path
              command 'bundle exec blocks build'
            end
          end
          migrate true
          migration_command "RAILS_ENV=#{ucnext_resource.rails_env} bundle exec rake db:migrate"
          purge_before_symlink %w(log tmp/pids config/database.yml config/secrets.yml config/auth.yml)
          before_symlink do
            execute 'db:seed' do
              environment 'PATH' => computed_path
              cwd release_path
              command "RAILS_ENV=#{ucnext_resource.rails_env} bundle exec rake db:seed; touch #{ucnext_resource.deploy_path}/shared/.seeded"
              not_if { ::File.exist?("#{ucnext_resource.deploy_path}/shared/.seeded") }
            end
          end
          symlinks(
            'log' => 'log',
            'pids' => 'tmp/pids'
          )
          restart_command "service ucnext-#{ucnext_resource.name} restart"
        end

        service "ucnext-#{new_resource.name}" do
          supports restart: true, status: true
          action [:enable, :start]
        end
      end

      action :delete do
        # stop service
        service "ucnext-#{new_resource.name}" do
          supports restart: true, status: true
          action [:disable, :stop]
        end

        # delete deploy path and remove init script.
        directory "#{new_resource.deploy_path}" do
          action :delete
        end

        file "/etc/init.d/ucnext-#{new_resource.name}" do
          action :delete
        end
      end
    end
  end
end
