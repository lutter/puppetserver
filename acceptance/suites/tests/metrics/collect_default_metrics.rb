test_name 'Default metrics are exported to graphite server'

graphite = agents.find { |agent| agent['platform'] =~ /el-7-x86_64/ }
skip_test 'This test requires an el7 agent' unless graphite

puppetserver_conf_file = options['puppetserver-config']
metrics_conf_file = "#{options['puppetserver-confdir']}/metrics.conf"
puppetservice = options['puppetservice']
environments_dir = "/etc/puppetlabs/code/environments"
manifests_dir = "#{environments_dir}/production/manifests"
sitepp = "#{manifests_dir}/site.pp"
graphite_port = 50000

step 'Backup puppetserver config files' do
  on master, "cp -pf #{puppetserver_conf_file} #{puppetserver_conf_file}.bak"
  on master, "cp -pf #{metrics_conf_file} #{metrics_conf_file}.bak"
end

teardown do
  on master, "mv -f #{puppetserver_conf_file}.bak #{puppetserver_conf_file}"
  on master, "mv #{metrics_conf_file}.bak #{metrics_conf_file}"
  if !master.is_pe?
    on master, "rm -f #{sitepp}"
  end
  bounce_service(master, puppetservice)
end

# This test assumes that at least some function metrics will be exported by
# the server.  For OSS, we create a manifest with a function in it, generate(),
# which should provoke the use of some function metrics during catalog
# compilation for an agent.  For PE, we shouldn't need to create a special
# manifest since any PE agent run should automatically have some functions
# exercised as part of its catalog compilation.  This test avoids putting the
# special manifest in place for PE in order to avoid unnecessarily dirtying up
# the code directory before any downstream tests are run, e.g., in the event
# that file sync is enabled.
if !master.is_pe?
  step 'Configuring manifest for exercising function metrics in agent run' do
    on master, "mkdir -p #{manifests_dir}"
    create_remote_file(master, sitepp, <<SITEPP)
notify { 'hello':
  message => generate("/bin/echo", "world")
}
SITEPP
    on(master, "chown -R puppet #{environments_dir}")
  end
end

tmp_module_dir = graphite.tmpdir('collect_default_metrics')

step 'Ensure apache is not trying to run on default ports' do
  on(graphite, "puppet module install puppetlabs-apache --codedir #{tmp_module_dir}")

  # Ensure apache is not trying to run on default ports (80 and 443) since
  # those would conflict when run on a node hosting the PE console.  Ensure
  # that the headers module is supported for the apache server since the
  # graphite server configuration depends upon it.
  apachepp = "#{tmp_module_dir}/apache.pp"
  create_remote_file(graphite, apachepp, <<APACHEPP)
class { 'apache':
  default_vhost => false,
}

include apache::mod::headers
APACHEPP
  on(graphite, "puppet apply #{apachepp} --codedir #{tmp_module_dir}")
end

step 'Install graphite (and grafana)' do
  on(graphite, "puppet module install puppetlabs-grafanadash --codedir #{tmp_module_dir}")
  on(graphite, "puppet apply -e \"include grafanadash::dev\" --codedir #{tmp_module_dir}")

  # Set max_creates_per_minute to 'inf' (in place of smaller default) in order
  # to speed up how quickly Graphite makes newly-created metrics available to
  # be queried - and, therefore, hopefully make this test run much more quickly.
  graphitepp = "#{tmp_module_dir}/graphite.pp"
  create_remote_file(graphite, graphitepp, <<GRAPHITEPP)
class { 'graphite':
  gr_web_cors_allow_from_all => true,
  gr_max_creates_per_minute => inf,
  gr_web_server_port => #{graphite_port}
}
GRAPHITEPP
  on(graphite, "puppet apply #{graphitepp} --codedir #{tmp_module_dir}")
end

step 'Enable graphite and profiler metrics in puppetserver configuration' do
  metrics_config =
      {"metrics" =>
           {"server-id" => master.hostname,
            "registries" =>
                {"puppetserver" =>
                     {"reporters" =>
                          {"graphite" =>
                               {"enabled" => true,
                                "update-interval-seconds" => 1}}}},
            "reporters" =>
                {"graphite" =>
                     {"host" => graphite.hostname,
                      "port" => 2003,
                      "update-interval-seconds" => 1}}}};

  modify_tk_config(master, metrics_conf_file, metrics_config)

  profiler_config = {"profiler" => {"enabled" => true}}
  modify_tk_config(master, puppetserver_conf_file, profiler_config)

  bounce_service(master, puppetservice)
end

step 'Generate some metrics by performing an agent run' do
  on(graphite, puppet("agent -t --no-use_cached_catalog --server #{master}"),
                       :acceptable_exit_codes => [0, 2])
end

default_metrics = build_default_metrics
full_results = Hash.new

step 'Query the graphite system for the default list of metrics' do
  full_results = query_metrics(master.hostname, "#{graphite}:#{graphite_port}",
                               default_metrics)

  puts "List of collected metrics:"
  full_results.each do |key, val|
    logger.info "#{key} => #{val[-1]}"
  end
end

step 'Validate that all metrics expected to be exported are in graphite server' do
  missing_metrics = build_missing_metrics_list(master, default_metrics, full_results)

  if missing_metrics.size != 0
    missing_metrics.each do |mm|
      logger.error "Expected to find a value for missing metric #{mm}"
    end
    assert(false, "FAIL: There are missing metrics.")
  end
end
