require 'open3'
require 'base64'
require 'json'
require 'fileutils'
require_relative '../tasks/run_cd4pe_job.rb'

describe 'run_cd4pe_job' do
  before(:all) do
    @logger = Logger.new
  end

  before(:each) do
    @working_dir = File.join(Dir.getwd, "test_working_dir")
    Dir.mkdir(@working_dir)

    # Ensure tests don't write to /etc/docker/certs.d
    @certs_dir = File.join(@working_dir, "certs.d")
    CD4PEJobRunner.send(:remove_const, :DOCKER_CERTS)
    CD4PEJobRunner.const_set(:DOCKER_CERTS, @certs_dir)

    @web_ui_endpoint = 'https://testtest.com'
    @job_token = 'alksjdbhfnadhsbf'
    @job_owner = 'carls cool carl'
    @job_instance_id = '17'
    @secrets = {
      secret1: "hello",
      secret2: "friend",
    }
    @windows_job = ENV['RUN_WINDOWS_UNIT_TESTS']
  end

  after(:each) do
    FileUtils.remove_dir(@working_dir)
    $stdout = STDOUT
  end

  describe 'set_job_env_vars' do
    it 'Sets the user-specified environment params.' do
      user_specified_env_vars = ["TEST_VAR_ONE=hello!", "TEXT_VAR_TWO=yellow-bird", "TEST_VAR_THREE=carl"]

      params = { 'env_vars' => user_specified_env_vars }

      set_job_env_vars(params)

      expect(ENV['TEST_VAR_ONE']).to eq('hello!')
      expect(ENV['TEXT_VAR_TWO']).to eq('yellow-bird')
      expect(ENV['TEST_VAR_THREE']).to eq('carl')
    end
  end

  describe 'make_dir' do
    it 'Makes working directory as specified.' do
      # validate dir does not exist
      test_dir = File.join(@working_dir, 'test_dir')
      expect(File.exist?(test_dir)).to be(false)

      # create dir and validate it exists
      make_dir(test_dir)
      expect(File.exist?(test_dir)).to be(true)

      # attempt to create again to validate it does not throw
      make_dir(test_dir)
    end
  end

  describe 'get_combined_exit_code' do
    it ('should be 0 if job and after_job_success are 0') do
      output = { job: { exit_code: 0}, after_job_success: { exit_code: 0} }
      test_code = get_combined_exit_code(output)
      expect(test_code).to eq(0)
    end

    it ('should be 1 if job or after_job_success are not 0') do
      output = { job: { exit_code: 1}, after_job_success: { exit_code: 0} }
      test_code = get_combined_exit_code(output)
      expect(test_code).to eq(1)

      output = { job: { exit_code: 125}, after_job_success: { exit_code: 0} }
      test_code = get_combined_exit_code(output)
      expect(test_code).to eq(1)

      output = { job: { exit_code: 0}, after_job_success: { exit_code: 1} }
      test_code = get_combined_exit_code(output)
      expect(test_code).to eq(1)

      output = { job: { exit_code: 0}, after_job_success: { exit_code: 125} }
      test_code = get_combined_exit_code(output)
      expect(test_code).to eq(1)

      output = { job: { exit_code: 1}, after_job_success: { exit_code: 125} }
      test_code = get_combined_exit_code(output)
      expect(test_code).to eq(1)
    end

    it ('should be 1 if job or after_job_failure are not 0') do
      output = { job: { exit_code: 1}, after_job_failure: { exit_code: 0} }
      test_code = get_combined_exit_code(output)
      expect(test_code).to eq(1)

      output = { job: { exit_code: 125}, after_job_failure: { exit_code: 0} }
      test_code = get_combined_exit_code(output)
      expect(test_code).to eq(1)

      output = { job: { exit_code: 0}, after_job_failure: { exit_code: 1} }
      test_code = get_combined_exit_code(output)
      expect(test_code).to eq(1)

      output = { job: { exit_code: 0}, after_job_failure: { exit_code: 125} }
      test_code = get_combined_exit_code(output)
      expect(test_code).to eq(1)

      output = { job: { exit_code: 1}, after_job_failure: { exit_code: 125} }
      test_code = get_combined_exit_code(output)
      expect(test_code).to eq(1)
    end
  end

  describe 'parse_args' do
    it 'should parse args appropriately' do
      key1 = "key1"
      value1 = "value1"
      key2 = "key2"
      value2 = "value2"
      key3 = "key3"
      value3 = "value3"

      args = [
        "#{key1}=#{value1}",
        "#{key2}=#{value2}",
        "#{key3}=#{value3}",
      ]

      parsed_args = parse_args(args)

      expect(parsed_args[key1]).to eq(value1)
      expect(parsed_args[key2]).to eq(value2)
      expect(parsed_args[key3]).to eq(value3)
    end
  end

  describe 'cd4pe_job_helper::initialize' do
    it 'Passes the docker run args through without modifying the structure.' do
      arg1 = '--testarg=woot'
      arg2 = '--otherarg=hello'
      arg3 = '--whatever=isclever'
      user_specified_docker_run_args = [arg1, arg2, arg3]

      job_helper = CD4PEJobRunner.new(windows_job: @windows_job, working_dir: @working_dir, docker_run_args: user_specified_docker_run_args, job_token: @job_token, web_ui_endpoint: @web_ui_endpoint, job_owner: @job_owner, job_instance_id: @job_instance_id, logger: @logger, secrets: @secrets)

      expect(job_helper.docker_run_args).to eq("#{arg1} #{arg2} #{arg3}")
    end

    it 'Sets the HOME and REPO_DIR env vars' do
      job_helper = CD4PEJobRunner.new(windows_job: @windows_job, working_dir: @working_dir, job_token: @job_token, web_ui_endpoint: @web_ui_endpoint, job_owner: @job_owner, job_instance_id: @job_instance_id, logger: @logger, secrets: @secrets)

      expect(ENV['HOME'] != nil).to be(true)
      expect(ENV['REPO_DIR']).to eq("#{@working_dir}/cd4pe_job/repo")
    end
  end

  describe 'cd4pe_job_helper::update_docker_image' do
    let(:test_docker_image) { 'puppetlabs/test:10.0.1' }
    it 'Generates a docker pull command.' do
      job_helper = CD4PEJobRunner.new(windows_job: @windows_job, working_dir: @working_dir, docker_image: test_docker_image, job_token: @job_token, web_ui_endpoint: @web_ui_endpoint, job_owner: @job_owner, job_instance_id: @job_instance_id, logger: @logger, secrets: @secrets)
      docker_pull_command = job_helper.get_docker_pull_cmd
      expect(docker_pull_command).to eq("docker pull #{test_docker_image}")
    end

    context 'with config' do
      let(:hostname) { 'host1' }
      let(:creds_json) { {auths: {hostname => {}}}.to_json }
      let(:creds_b64) { Base64.encode64(creds_json) }
      let(:cert_txt) { 'junk' }
      let(:cert_b64) { Base64.encode64(cert_txt) }

      it 'Uses config when present.' do
        job_helper = CD4PEJobRunner.new(windows_job: @windows_job, working_dir: @working_dir, docker_image: test_docker_image, docker_pull_creds: creds_b64, job_token: @job_token, web_ui_endpoint: @web_ui_endpoint, job_owner: @job_owner, job_instance_id: @job_instance_id, logger: @logger, secrets: @secrets)
        config_json = File.join(@working_dir, '.docker', 'config.json')
        expect(File.exist?(config_json)).to be(true)
        expect(File.read(config_json)).to eq(creds_json)

        docker_pull_command = job_helper.get_docker_pull_cmd
        expect(docker_pull_command).to eq("docker --config #{File.join(@working_dir, '.docker')} pull #{test_docker_image}")
      end

      it 'Registers the CA cert when provided.' do
        job_helper = CD4PEJobRunner.new(windows_job: @windows_job, working_dir: @working_dir, docker_image: test_docker_image, docker_pull_creds: creds_b64, base_64_ca_cert: cert_b64, job_token: @job_token, web_ui_endpoint: @web_ui_endpoint, job_owner: @job_owner, job_instance_id: @job_instance_id, logger: @logger, secrets: @secrets)

        cert_file = File.join(@certs_dir, hostname, 'ca.crt')
        expect(File.exist?(cert_file)).to be(true)
        expect(File.read(cert_file)).to eq(cert_txt)
      end
    end
  end

  describe 'cd4pe_job_helper::get_docker_run_cmd' do
    it 'Generates the correct docker run command.' do
      test_manifest_type = "AFTER_JOB_SUCCESS"
      test_docker_image = 'puppetlabs/test:10.0.1'
      arg1 = '--testarg=woot'
      arg2 = '--otherarg=hello'
      arg3 = '--whatever=doesntmatter'
      user_specified_docker_run_args = [arg1, arg2, arg3]
      job_type = @windows_job ? 'windows' : 'unix'

      job_helper = CD4PEJobRunner.new(windows_job: @windows_job, working_dir: @working_dir, docker_image: test_docker_image, docker_run_args: user_specified_docker_run_args, job_token: @job_token, web_ui_endpoint: @web_ui_endpoint, job_owner: @job_owner, job_instance_id: @job_instance_id, logger: @logger, secrets: @secrets)

      docker_run_command = job_helper.get_docker_run_cmd(test_manifest_type)
      cmd_parts = docker_run_command.split(' ')

      expect(cmd_parts[0]).to eq('docker')
      expect(cmd_parts[1]).to eq('run')
      expect(cmd_parts[2]).to eq('--rm')
      expect(cmd_parts[3]).to eq(arg1)
      expect(cmd_parts[4]).to eq(arg2)
      expect(cmd_parts[5]).to eq(arg3)
      expect(cmd_parts[6]).to eq('-e')
      expect(cmd_parts[7]).to eq('secret1')
      expect(cmd_parts[8]).to eq('-e')
      expect(cmd_parts[9]).to eq('secret2')
      expect(cmd_parts[10]).to eq('-v')
      expect(cmd_parts[11].end_with?("/#{File.basename(@working_dir)}/cd4pe_job/repo:/repo\"")).to be(true)
      expect(cmd_parts[12]).to eq('-v')
      expect(cmd_parts[13].end_with?("/#{File.basename(@working_dir)}/cd4pe_job/jobs/#{job_type}:/cd4pe_job\"")).to be(true)
      expect(cmd_parts[14]).to eq(test_docker_image)
      expect(cmd_parts[15]).to eq('"/cd4pe_job/AFTER_JOB_SUCCESS"')
    end
  end
end

describe 'cd4pe_job_helper::run_job' do

  before(:all) do
    @logger = Logger.new
    @working_dir = File.join(Dir.getwd, "test_working_dir")
    cd4pe_job_dir = File.join(@working_dir, 'cd4pe_job')
    jobs_dir = File.join(cd4pe_job_dir, 'jobs')
    os_dir = File.join(jobs_dir, 'unix')
    @job_script = File.join(os_dir, 'JOB')
    @after_job_success_script = File.join(os_dir, 'AFTER_JOB_SUCCESS')
    @after_job_failure_script = File.join(os_dir, 'AFTER_JOB_FAILURE')

    @windows_job = ENV['RUN_WINDOWS_UNIT_TESTS']
    if @windows_job
      os_dir = File.join(jobs_dir, 'windows')
      @job_script = File.join(os_dir, 'JOB.ps1')
      @after_job_success_script = File.join(os_dir, 'AFTER_JOB_SUCCESS.ps1')
      @after_job_failure_script = File.join(os_dir, 'AFTER_JOB_FAILURE.ps1')
    end

    Dir.mkdir(@working_dir)
    Dir.mkdir(cd4pe_job_dir)
    Dir.mkdir(jobs_dir)
    Dir.mkdir(os_dir)

    File.write(@job_script, '')
    File.chmod(0775, @job_script)
    File.write(@after_job_success_script, '')
    File.chmod(0775, @after_job_success_script)
    File.write(@after_job_failure_script, '')
    File.chmod(0775, @after_job_failure_script)
  end

  after(:all) do
    FileUtils.remove_dir(@working_dir)
  end

  it 'Runs the success script after a successful script run' do
    $stdout = StringIO.new

    expected_output = 'in job script'
    after_job_success_message = 'in after success script'

    File.write(@job_script, "echo \"#{expected_output}\"")
    File.write(@after_job_success_script, "echo \"#{after_job_success_message}\"")

    job_helper = CD4PEJobRunner.new(windows_job: @windows_job, working_dir: @working_dir, job_token: @job_token, web_ui_endpoint: @web_ui_endpoint, job_owner: @job_owner, job_instance_id: @job_instance_id, logger: @logger, secrets: @secrets)
    output = job_helper.run_job

    expect(output[:job][:exit_code]).to eq(0)
    expect(output[:job][:message]).to eq("#{expected_output}\n")
    expect(output[:after_job_success][:exit_code]).to eq(0)
    expect(output[:after_job_success][:message]).to eq("#{after_job_success_message}\n")

  end

  it 'Runs the failure script after a failed script run' do
    $stdout = StringIO.new

    if @windows_job
      after_job_failure_message = 'in after failure script'
      File.write(@job_script, "$ErrorActionPreference = 'Stop'; this command does not exist")
      File.write(@after_job_failure_script, "echo \"#{after_job_failure_message}\"")

      job_helper = CD4PEJobRunner.new(windows_job: @windows_job, working_dir: @working_dir, job_token: @job_token, web_ui_endpoint: @web_ui_endpoint, job_owner: @job_owner, job_instance_id: @job_instance_id, logger: @logger, secrets: @secrets)
      output = job_helper.run_job

      expect(output[:job][:exit_code]).to eq(1)
      expect(output[:job][:message].start_with?("this : The term 'this' is not recognized as the name of a cmdlet")).to be(true)
      expect(output[:after_job_failure][:exit_code]).to eq(0)
      expect(output[:after_job_failure][:message]).to eq("#{after_job_failure_message}\n")
    else
      after_job_failure_message = 'in after failure script'
      File.write(@job_script, "this command does not exist")
      File.write(@after_job_failure_script, "echo \"#{after_job_failure_message}\"")

      job_helper = CD4PEJobRunner.new(windows_job: @windows_job, working_dir: @working_dir, job_token: @job_token, web_ui_endpoint: @web_ui_endpoint, job_owner: @job_owner, job_instance_id: @job_instance_id, logger: @logger, secrets: @secrets)
      output = job_helper.run_job

      expect(output[:job][:exit_code]).to eq(127)
      expect(output[:job][:message].end_with?("command not found\n")).to be(true)
      expect(output[:after_job_failure][:exit_code]).to eq(0)
      expect(output[:after_job_failure][:message]).to eq("#{after_job_failure_message}\n")
    end


  end
end


describe 'cd4pe_job_helper::unzip' do
  before(:all) do
    @windows_job = ENV['RUN_WINDOWS_UNIT_TESTS']
    @working_dir = File.join(Dir.getwd, 'test_working_dir')
    @test_tar_files_dir = File.join(Dir.getwd, 'spec', 'fixtures', 'test_tar_files')
    Dir.mkdir(@working_dir)
  end

  after(:all) do
    FileUtils.remove_dir(@working_dir)
  end

  it 'unzips a single file tar.gz' do
    single_file_tar = File.join(@test_tar_files_dir, 'gzipSingleFileTest.tar.gz')
    single_file = File.join(@working_dir, 'gzipSingleFileTest')
    GZipHelper.unzip(single_file_tar, @working_dir)

    expect(File.exist?(single_file)).to be(true)

    file_data =  File.read(single_file)
    expect(file_data).to eql('test data')
  end

  it 'unzips a single level directory tar.gz' do
    single_level_dir_tar = File.join(@test_tar_files_dir, 'gzipSingleLevelDirectoryTest.tar.gz')
    single_level_dir = File.join(@working_dir, 'gzipSingleLevelDirectoryTest')
    GZipHelper.unzip(single_level_dir_tar, @working_dir)

    expect(File.exist?(single_level_dir)).to be(true)
    test_file_1 = File.join(single_level_dir, 'testFile1')
    test_file_2 = File.join(single_level_dir, 'testFile2')
    expect(File.exist?(test_file_1)).to be(true)
    expect(File.exist?(test_file_2)).to be(true)

    file_1_data =  File.read(test_file_1)
    file_2_data =  File.read(test_file_2)
    expect(file_1_data).to eql('I am test file 1!')
    expect(file_2_data).to eql('I am test file 2!')
  end

  it 'unzips a multi level directory tar.gz' do
    multi_level_dir_tar = File.join(@test_tar_files_dir, 'gzipMultiLevelDirectoryTest.tar.gz')
    multi_level_dir = File.join(@working_dir, 'gzipMultiLevelDirectoryTest')
    sub_dir = File.join(multi_level_dir, 'subDir')
    GZipHelper.unzip(multi_level_dir_tar, @working_dir)

    # root dir
    expect(File.exist?(multi_level_dir)).to be(true)
    root_file_1 = File.join(multi_level_dir, 'rootFile1')
    root_file_2 = File.join(multi_level_dir, 'rootFile2')
    expect(File.exist?(root_file_1)).to be(true)
    expect(File.exist?(root_file_2)).to be(true)

    root_file_1_data =  File.read(root_file_1)
    root_file_2_data =  File.read(root_file_2)
    expect(root_file_1_data).to eql('I am in root 1!')
    expect(root_file_2_data).to eql('I am in root 2!')

    # sub dir
    expect(File.exist?(sub_dir)).to be(true)
    sub_file_1 = File.join(sub_dir, 'subDirFile1')
    sub_file_2 = File.join(sub_dir, 'subDirFile2')
    expect(File.exist?(sub_file_1)).to be(true)
    expect(File.exist?(sub_file_2)).to be(true)

    sub_file_1_data =  File.read(sub_file_1)
    sub_file_2_data =  File.read(sub_file_2)
    expect(sub_file_1_data).to eql('I am in sub 1!')
    expect(sub_file_2_data).to eql('I am in sub 2!')
  end

  it 'maintains file permissions when extracting' do
    executable_tar = File.join(@test_tar_files_dir, 'executableFileTest.tar.gz')
    executable = File.join(@working_dir, "executableFileTest")

    if @windows_job
      executable_tar = File.join(@test_tar_files_dir, 'executableWindowsFileTest.tar.gz')
      filePath = File.join(@working_dir, "windows", "executableWindowsFileTest.ps1")
      executable = "powershell \"& {&'#{filePath}'}\""
    end

    GZipHelper.unzip(executable_tar, @working_dir)

    output = ''
    exit_code = 0

    Open3.popen2e(executable) do |stdin, stdout_stderr, wait_thr|
      exit_code = wait_thr.value.exitstatus
      output = stdout_stderr.read
    end

    expect(exit_code).to eql(0)
    expect(output).to eql("hello!\n")
  end

  it 'unzips a file with a filename > 100 characters' do
    single_level_dir_tar = File.join(@test_tar_files_dir, 'long_file_name.tar.gz')
    single_level_dir = File.join(@working_dir, 'long_file_name')
    GZipHelper.unzip(single_level_dir_tar, @working_dir)

    expect(File.exist?(single_level_dir)).to be(true)
    test_file_1 = File.join(single_level_dir, 'IAMASUPERLONGFILENAMEIAMASUPERLONGFILENAMEIAMASUPERLONGFILENAMEIAMASUPERLONGFILENAMEIAMASUPERLONGFILENAMEIAMASUPERLONGFILENAMEIAMASUPERLONGFILENAMEIAMASUPERLONGFILENAMEIAMASUPE')
    expect(File.exist?(test_file_1)).to be(true)
  end

end