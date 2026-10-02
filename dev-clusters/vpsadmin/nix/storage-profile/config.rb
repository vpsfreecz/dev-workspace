# frozen_string_literal: true

require_relative 'storage_profile_impl'
DevClusters::VpsAdminStorageProfile.configure(
  JSON.parse(File.binread(File.join(__dir__, 'storage-profile.json')))
)
