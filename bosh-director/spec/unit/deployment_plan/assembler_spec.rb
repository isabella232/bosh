require 'spec_helper'

module Bosh::Director
  describe DeploymentPlan::Assembler do
    subject(:assembler) { DeploymentPlan::Assembler.new(deployment_plan, stemcell_manager, cloud, blobstore, logger, event_log) }
    let(:deployment_plan) { instance_double('Bosh::Director::DeploymentPlan::Planner') }
    let(:stemcell_manager) { nil }
    let(:event_log) { Config.event_log }

    let(:blobstore) { instance_double('Bosh::Blobstore::Client') }

    let(:cloud) { instance_double('Bosh::Cloud') }

    it 'should bind releases' do
      r1 = instance_double('Bosh::Director::DeploymentPlan::ReleaseVersion', name: 'r1')
      r2 = instance_double('Bosh::Director::DeploymentPlan::ReleaseVersion', name: 'r2')

      expect(deployment_plan).to receive(:releases).and_return([r1, r2])

      expect(r1).to receive(:bind_model)
      expect(r2).to receive(:bind_model)

      expect(assembler).to receive(:with_release_locks).with(['r1', 'r2']).and_yield
      assembler.bind_releases
    end

    it 'should bind existing VMs' do
      vm_model1 = Models::Vm.make
      vm_model2 = Models::Vm.make

      allow(deployment_plan).to receive(:vms).and_return([vm_model1, vm_model2])

      expect(assembler).to receive(:bind_existing_vm).with(vm_model1, an_instance_of(Mutex))
      expect(assembler).to receive(:bind_existing_vm).with(vm_model2, an_instance_of(Mutex))

      assembler.bind_existing_deployment
    end

    it 'should bind stemcells' do
      sc1 = instance_double('Bosh::Director::DeploymentPlan::Stemcell')
      sc2 = instance_double('Bosh::Director::DeploymentPlan::Stemcell')

      rp1 = instance_double('Bosh::Director::DeploymentPlan::ResourcePool', :stemcell => sc1)
      rp2 = instance_double('Bosh::Director::DeploymentPlan::ResourcePool', :stemcell => sc2)

      expect(deployment_plan).to receive(:resource_pools).and_return([rp1, rp2])

      expect(sc1).to receive(:bind_model)
      expect(sc2).to receive(:bind_model)

      assembler.bind_stemcells
    end

    describe '#bind_templates' do
      it 'should bind templates' do
        r1 = instance_double('Bosh::Director::DeploymentPlan::ReleaseVersion')
        r2 = instance_double('Bosh::Director::DeploymentPlan::ReleaseVersion')

        expect(deployment_plan).to receive(:releases).and_return([r1, r2])
        allow(deployment_plan).to receive(:jobs).and_return([])

        expect(r1).to receive(:bind_templates)
        expect(r2).to receive(:bind_templates)

        assembler.bind_templates
      end

      it 'validates the jobs' do
        j1 = instance_double('Bosh::Director::DeploymentPlan::Job')
        j2 = instance_double('Bosh::Director::DeploymentPlan::Job')

        expect(deployment_plan).to receive(:jobs).and_return([j1, j2])
        allow(deployment_plan).to receive(:releases).and_return([])

        expect(j1).to receive(:validate_package_names_do_not_collide!).once
        expect(j2).to receive(:validate_package_names_do_not_collide!).once

        assembler.bind_templates
      end

      context 'when the job validation fails' do
        it "bubbles up the exception" do
          j1 = instance_double('Bosh::Director::DeploymentPlan::Job')
          j2 = instance_double('Bosh::Director::DeploymentPlan::Job')

          allow(deployment_plan).to receive(:jobs).and_return([j1, j2])
          allow(deployment_plan).to receive(:releases).and_return([])

          expect(j1).to receive(:validate_package_names_do_not_collide!).once
          expect(j2).to receive(:validate_package_names_do_not_collide!).once.and_raise('Unable to deploy manifest')

          expect { assembler.bind_templates }.to raise_error('Unable to deploy manifest')
        end
      end
    end

    describe '#bind_unallocated_vms' do
      it 'binds unallocated VMs for each job' do
        j1 = instance_double('Bosh::Director::DeploymentPlan::Job')
        j2 = instance_double('Bosh::Director::DeploymentPlan::Job')
        expect(deployment_plan).to receive(:jobs_starting_on_deploy).and_return([j1, j2])

        [j1, j2].each do |job|
          expect(job).to receive(:bind_unallocated_vms).with(no_args).ordered
        end

        assembler.bind_unallocated_vms
      end
    end

    describe '#bind_existing_vm' do
      before do
        @lock = Mutex.new
        @vm_model = Models::Vm.make(:agent_id => 'foo')
      end

      it 'should bind an instance if present' do
        instance = Models::Instance.make(:vm => @vm_model)
        state = { 'state' => 'foo' }

        expect(assembler).to receive(:get_state).with(@vm_model).
          and_return(state)
        expect(assembler).to receive(:bind_instance).
          with(instance, state)
        assembler.bind_existing_vm(@vm_model, @lock)
      end

      context "when there is no instance" do
        context "but the VMs resource pool still exists" do
          let(:cloud_config) { Models::CloudConfig.make }
          let(:deployment_plan) { DeploymentPlan::Planner.new(planner_attributes, deployment_model.manifest, cloud_config, deployment_model) }
          let(:planner_attributes) { {name: manifest_hash['name'], properties: manifest_hash['properties']} }
          let(:deployment_model) { Models::Deployment.make(manifest: Psych.dump(manifest_hash)) }
          let(:manifest_hash) { Bosh::Spec::Deployments.simple_manifest }
          let(:network_fake) { DeploymentPlan::Network.new(deployment_plan, {'name' => resource_pool_manifest['network']}) }
          let(:network_bar) { DeploymentPlan::Network.new(deployment_plan, {'name' => 'bar'}) }
          let(:network_baz) { DeploymentPlan::Network.new(deployment_plan, {'name' => 'baz'}) }
          let(:resource_pool) { DeploymentPlan::ResourcePool.new(deployment_plan, resource_pool_manifest, logger) }
          let(:resource_pool_manifest) do
            {
              'name' => 'baz',
              'size' => 1,
              'cloud_properties' => {},
              'stemcell' => {
                'name' => 'fake-stemcell',
                'version' => 'fake-stemcell-version',
              },
              'network' => 'fake-network',
            }
          end
          let(:reservations) do
            {
              'fake-network' => NetworkReservation.new(type: NetworkReservation::STATIC),
              'bar' => NetworkReservation.new(type: NetworkReservation::DYNAMIC),
              'baz' => NetworkReservation.new(type: NetworkReservation::STATIC),
            }
          end

          before do
            # add mock network
            deployment_plan.add_network(network_fake)
            deployment_plan.add_network(network_bar)
            deployment_plan.add_network(network_baz)

            # release is not implemented in the base Network object
            allow(network_fake).to receive(:release)
            allow(network_bar).to receive(:release)
            allow(network_baz).to receive(:release)

            # add resource pool
            deployment_plan.add_resource_pool(resource_pool)

            state = {'resource_pool' => {'name' => 'baz'}}

            expect(assembler).to receive(:get_state).with(@vm_model).
                and_return(state)
          end

          it 'should delete the VM, releasing network reservations' do
            expect(deployment_plan).to receive(:delete_vm).with(@vm_model)
            assembler.bind_existing_vm(@vm_model, @lock)
          end
        end

        context "and the VMs resource pool no longer exists" do
          it 'should delete the vm' do
            state = {'resource_pool' => {'name' => 'baz'}}

            allow(deployment_plan).to receive(:resource_pool).with('baz').
                and_return(nil)

            expect(assembler).to receive(:get_state).with(@vm_model).
                and_return(state)
            expect(deployment_plan).to receive(:delete_vm).with(@vm_model)
            assembler.bind_existing_vm(@vm_model, @lock)
          end
        end
      end
    end

    describe '#bind_instance' do
      let(:instance_model) { Models::Instance.make(:job => 'foo', :index => 3) }
      before { allow(instance_model).to receive(:vm).and_return(vm_model)}
      let(:vm_model) { Bosh::Director::Models::Vm.make }

      it 'should associate the instance to the instance spec' do
        state = { 'state' => 'baz' }

        instance = instance_double('Bosh::Director::DeploymentPlan::Instance')
        resource_pool = instance_double('Bosh::Director::DeploymentPlan::ResourcePool')
        job = instance_double('Bosh::Director::DeploymentPlan::Job')
        allow(job).to receive(:instance).with(3).and_return(instance)
        allow(job).to receive(:resource_pool).and_return(resource_pool)
        allow(deployment_plan).to receive(:job).with('foo').and_return(job)
        allow(deployment_plan).to receive(:job_rename).and_return({})
        allow(deployment_plan).to receive(:rename_in_progress?).and_return(false)

        expect(instance).to receive(:bind_existing_instance).with(instance_model, state)

        assembler.bind_instance(instance_model, state)
      end

      it 'should update the instance name if it is being renamed' do
        state = { 'state' => 'baz' }

        instance = instance_double('Bosh::Director::DeploymentPlan::Instance')
        resource_pool = instance_double('Bosh::Director::DeploymentPlan::ResourcePool')
        job = instance_double('Bosh::Director::DeploymentPlan::Job')
        allow(job).to receive(:instance).with(3).and_return(instance)
        allow(job).to receive(:resource_pool).and_return(resource_pool)
        allow(deployment_plan).to receive(:job).with('bar').and_return(job)
        allow(deployment_plan).to receive(:job_rename).
          and_return({ 'old_name' => 'foo', 'new_name' => 'bar' })
        allow(deployment_plan).to receive(:rename_in_progress?).and_return(true)

        expect(instance).to receive(:bind_existing_instance).with(instance_model, state)

        assembler.bind_instance(instance_model, state)
      end

      it "should mark the instance for deletion when it's no longer valid" do
        state = { 'state' => 'baz' }
        allow(deployment_plan).to receive(:job).with('foo').and_return(nil)
        expect(deployment_plan).to receive(:delete_instance) do |instance|
          expect(instance.model).to eq(instance_model)
        end
        allow(deployment_plan).to receive(:job_rename).and_return({})
        allow(deployment_plan).to receive(:rename_in_progress?).and_return(false)

        assembler.bind_instance(instance_model, state)
      end
    end

    describe '#get_state' do
      it 'should return the processed agent state' do
        state = { 'state' => 'baz' }

        vm_model = Models::Vm.make(:agent_id => 'agent-1')
        client = double('AgentClient')
        expect(AgentClient).to receive(:with_vm).with(vm_model).and_return(client)

        expect(client).to receive(:get_state).and_return(state)
        expect(assembler).to receive(:verify_state).with(vm_model, state)
        expect(assembler).to receive(:migrate_legacy_state).
          with(vm_model, state)

        expect(assembler.get_state(vm_model)).to eq(state)
      end

      context 'when the returned state contains top level "release" key' do
        let(:agent_client) { double('AgentClient') }
        let(:vm_model) { Models::Vm.make(:agent_id => 'agent-1') }
        before { allow(AgentClient).to receive(:with_vm).with(vm_model).and_return(agent_client) }

        it 'prunes the legacy "release" data to avoid unnecessary update' do
          legacy_state = { 'release' => 'cf', 'other' => 'data', 'job' => {} }
          final_state = { 'other' => 'data', 'job' => {} }
          allow(agent_client).to receive(:get_state).and_return(legacy_state)

          allow(assembler).to receive(:verify_state).with(vm_model, legacy_state)
          allow(assembler).to receive(:migrate_legacy_state).with(vm_model, legacy_state)

          expect(assembler.get_state(vm_model)).to eq(final_state)
        end

        context 'and the returned state contains a job level release' do
          it 'prunes the legacy "release" in job section so as to avoid unnecessary update' do
            legacy_state = {
              'release' => 'cf',
              'other' => 'data',
              'job' => {
                'release' => 'sql-release',
                'more' => 'data',
              },
            }
            final_state = {
              'other' => 'data',
              'job' => {
                'more' => 'data',
              },
            }
            allow(agent_client).to receive(:get_state).and_return(legacy_state)

            allow(assembler).to receive(:verify_state).with(vm_model, legacy_state)
            allow(assembler).to receive(:migrate_legacy_state).with(vm_model, legacy_state)

            expect(assembler.get_state(vm_model)).to eq(final_state)
          end
        end

        context 'and the returned state does not contain a job level release' do
          it 'returns the job section as-is' do
            legacy_state = {
              'release' => 'cf',
              'other' => 'data',
              'job' => {
                'more' => 'data',
              },
            }
            final_state = {
              'other' => 'data',
              'job' => {
                'more' => 'data',
              },
            }
            allow(agent_client).to receive(:get_state).and_return(legacy_state)

            allow(assembler).to receive(:verify_state).with(vm_model, legacy_state)
            allow(assembler).to receive(:migrate_legacy_state).with(vm_model, legacy_state)

            expect(assembler.get_state(vm_model)).to eq(final_state)
          end
        end
      end

      context 'when the returned state does not contain top level "release" key' do
        let(:agent_client) { double('AgentClient') }
        let(:vm_model) { Models::Vm.make(:agent_id => 'agent-1') }
        before do
          allow(AgentClient).to receive(:with_vm).with(vm_model).and_return(agent_client)
        end

        context 'and the returned state contains a job level release' do
          it 'prunes the legacy "release" in job section so as to avoid unnecessary update' do
            legacy_state = {
              'other' => 'data',
              'job' => {
                'release' => 'sql-release',
                'more' => 'data',
              },
            }
            final_state = {
              'other' => 'data',
              'job' => {
                'more' => 'data',
              },
            }
            allow(agent_client).to receive(:get_state).and_return(legacy_state)

            allow(assembler).to receive(:verify_state).with(vm_model, legacy_state)
            allow(assembler).to receive(:migrate_legacy_state).with(vm_model, legacy_state)

            expect(assembler.get_state(vm_model)).to eq(final_state)
          end
        end

        context 'and the returned state does not contain a job level release' do
          it 'returns the job section as-is' do
            legacy_state = {
              'release' => 'cf',
              'other' => 'data',
              'job' => {
                'more' => 'data',
              },
            }
            final_state = {
              'other' => 'data',
              'job' => {
                'more' => 'data',
              },
            }
            allow(agent_client).to receive(:get_state).and_return(legacy_state)

            allow(assembler).to receive(:verify_state).with(vm_model, legacy_state)
            allow(assembler).to receive(:migrate_legacy_state).with(vm_model, legacy_state)

            expect(assembler.get_state(vm_model)).to eq(final_state)
          end
        end
      end
    end

    describe '#verify_state' do
      before do
        @deployment = Models::Deployment.make(:name => 'foo')
        @vm_model = Models::Vm.make(:deployment => @deployment, :cid => 'foo')
        allow(deployment_plan).to receive(:name).and_return('foo')
        allow(deployment_plan).to receive(:model).and_return(@deployment)
      end

      it 'should do nothing when VM is ok' do
        assembler.verify_state(@vm_model, { 'deployment' => 'foo' })
      end

      it 'should do nothing when instance is ok' do
        Models::Instance.make(
          :deployment => @deployment, :vm => @vm_model, :job => 'bar', :index => 11)
        assembler.verify_state(@vm_model, {
          'deployment' => 'foo',
          'job' => {
            'name' => 'bar'
          },
          'index' => 11
        })
      end

      it 'should make sure VM and instance belong to the same deployment' do
        other_deployment = Models::Deployment.make
        Models::Instance.make(
          :deployment => other_deployment, :vm => @vm_model, :job => 'bar',
          :index => 11)
        expect {
          assembler.verify_state(@vm_model, {
            'deployment' => 'foo',
            'job' => { 'name' => 'bar' },
            'index' => 11
          })
        }.to raise_error(VmInstanceOutOfSync,
                             "VM `foo' and instance `bar/11' " +
                               "don't belong to the same deployment")
      end

      it 'should make sure the state is a Hash' do
        expect {
          assembler.verify_state(@vm_model, 'state')
        }.to raise_error(AgentInvalidStateFormat, /expected Hash/)
      end

      it 'should make sure the deployment name is correct' do
        expect {
          assembler.verify_state(@vm_model, { 'deployment' => 'foz' })
        }.to raise_error(AgentWrongDeployment,
                             "VM `foo' is out of sync: expected to be a part " +
                               "of deployment `foo' but is actually a part " +
                               "of deployment `foz'")
      end

      it 'should make sure the job and index exist' do
        expect {
          assembler.verify_state(@vm_model, {
            'deployment' => 'foo',
            'job' => { 'name' => 'bar' },
            'index' => 11
          })
        }.to raise_error(AgentUnexpectedJob,
                             "VM `foo' is out of sync: it reports itself as " +
                               "`bar/11' but there is no instance reference in DB")
      end

      it 'should make sure the job and index are correct' do
        expect {
          allow(deployment_plan).to receive(:job_rename).and_return({})
          allow(deployment_plan).to receive(:rename_in_progress?).and_return(false)
          Models::Instance.make(
            :deployment => @deployment, :vm => @vm_model, :job => 'bar', :index => 11)
          assembler.verify_state(@vm_model, {
            'deployment' => 'foo',
            'job' => { 'name' => 'bar' },
            'index' => 22
          })
        }.to raise_error(AgentJobMismatch,
                             "VM `foo' is out of sync: it reports itself as " +
                               "`bar/22' but according to DB it is `bar/11'")
      end
    end

    describe '#migrate_legacy_state'

    describe '#bind_instance_networks' do
      it 'binds unallocated VMs for each job' do
        j1 = instance_double('Bosh::Director::DeploymentPlan::Job')
        j2 = instance_double('Bosh::Director::DeploymentPlan::Job')
        expect(deployment_plan).to receive(:jobs_starting_on_deploy).and_return([j1, j2])

        [j1, j2].each do |job|
          expect(job).to receive(:bind_instance_networks).with(no_args).ordered
        end

        assembler.bind_instance_networks
      end
    end


    describe '#bind_dns' do
      it 'uses DnsBinder to create dns records for deployment' do
        binder = instance_double('Bosh::Director::DeploymentPlan::DnsBinder')
        allow(DeploymentPlan::DnsBinder).to receive(:new).with(deployment_plan).and_return(binder)
        expect(binder).to receive(:bind_deployment).with(no_args)
        assembler.bind_dns
      end
    end
  end
end
