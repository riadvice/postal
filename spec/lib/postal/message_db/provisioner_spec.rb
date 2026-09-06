# frozen_string_literal: true

require "rails_helper"

describe Postal::MessageDB::Provisioner do
  subject(:provisioner) { described_class.new(database) }

  let(:database) { instance_double(Postal::MessageDB::Database, database_name: "postal-test") }

  before do
    allow(database).to receive(:escape_identifier) { |identifier| "`#{identifier.to_s.gsub('`', '``')}`" }
  end

  def mysql_error(message)
    Mysql2::Error.new(message)
  end

  describe "#exists?" do
    it "returns true when the schema is listed" do
      allow(database).to receive(:query).with("SELECT schema_name FROM `information_schema`.`schemata` WHERE schema_name = 'postal-test'").and_return([{ "schema_name" => "postal-test" }])
      expect(provisioner.exists?).to be true
    end

    it "returns false when the schema is not listed" do
      allow(database).to receive(:query).and_return([])
      expect(provisioner.exists?).to be false
    end
  end

  describe "#create" do
    it "creates the database and returns true" do
      allow(database).to receive(:query).and_return([])
      expect(provisioner.create).to be true
      expect(database).to have_received(:query).with("CREATE DATABASE `postal-test` CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci;")
    end

    it "returns false when the database already exists" do
      allow(database).to receive(:query).and_raise(mysql_error("Can't create database 'postal-test'; database exists"))
      expect(provisioner.create).to be false
    end

    it "re-raises other errors" do
      allow(database).to receive(:query).and_raise(mysql_error("Access denied for user 'postal'@'localhost'"))
      expect { provisioner.create }.to raise_error(Mysql2::Error, /Access denied/)
    end

    it "re-raises errors which only mention the database existing elsewhere in the message" do
      allow(database).to receive(:query).and_raise(mysql_error("Database Exists"))
      expect { provisioner.create }.to raise_error(Mysql2::Error)
    end
  end

  describe "#drop" do
    it "drops the database and returns true" do
      allow(database).to receive(:query).and_return([])
      expect(provisioner.drop).to be true
      expect(database).to have_received(:query).with("DROP DATABASE `postal-test`;")
    end

    it "returns false when the database does not exist" do
      allow(database).to receive(:query).and_raise(mysql_error("Can't drop database 'postal-test'; database doesn't exist"))
      expect(provisioner.drop).to be false
    end

    it "re-raises other errors" do
      allow(database).to receive(:query).and_raise(mysql_error("Access denied"))
      expect { provisioner.drop }.to raise_error(Mysql2::Error, /Access denied/)
    end
  end

  describe "#create_table" do
    before do
      allow(database).to receive(:query).and_return([])
    end

    it "builds a CREATE TABLE query with the database name" do
      provisioner.create_table(:things, columns: { id: "int(11) NOT NULL AUTO_INCREMENT", name: "varchar(255)" })
      expect(database).to have_received(:query).with(
        "CREATE TABLE `postal-test`.`things` (`id` int(11) NOT NULL AUTO_INCREMENT, `name` varchar(255), PRIMARY KEY (`id`)) ENGINE=InnoDB AUTO_INCREMENT=1 DEFAULT CHARSET=utf8mb4;"
      )
    end

    it "includes indexes, unique indexes and a custom primary key" do
      provisioner.create_table(:things, columns: { id: "int(11)" }, indexes: { on_name: "`name`" }, unique_indexes: { on_token: "`token`" }, primary_key: "`id`, `name`")
      expect(database).to have_received(:query).with(
        "CREATE TABLE `postal-test`.`things` (`id` int(11), KEY `on_name` (`name`) USING BTREE, UNIQUE KEY `on_token` (`token`), " \
        "PRIMARY KEY (`id`, `name`)) ENGINE=InnoDB AUTO_INCREMENT=1 DEFAULT CHARSET=utf8mb4;"
      )
    end

    it "escapes backticks in the table name" do
      provisioner.create_table("things`; DROP DATABASE `postal-test`; -- ", columns: { id: "int(11)" })
      expect(database).to have_received(:query).with(a_string_starting_with("CREATE TABLE `postal-test`.`things``; DROP DATABASE ``postal-test``; -- `"))
    end
  end

  describe "#drop_table" do
    before do
      allow(database).to receive(:query).and_return([])
    end

    it "drops the table within the database" do
      provisioner.drop_table("raw-2024-01-15")
      expect(database).to have_received(:query).with("DROP TABLE `postal-test`.`raw-2024-01-15`")
    end

    it "escapes backticks in the table name" do
      provisioner.drop_table("x`; DROP DATABASE `postal-test`; -- ")
      expect(database).to have_received(:query).with("DROP TABLE `postal-test`.`x``; DROP DATABASE ``postal-test``; -- `")
    end
  end

  describe "#clean" do
    it "truncates every table" do
      allow(database).to receive(:query).and_return([])
      provisioner.clean
      expect(database).to have_received(:query).with("TRUNCATE `postal-test`.`messages`")
      expect(database).to have_received(:query).with("TRUNCATE `postal-test`.`webhook_requests`")
      expect(database).to have_received(:query).exactly(14).times
    end
  end

  describe "#create_raw_table" do
    it "creates the table and records its size" do
      allow(database).to receive(:query).and_return([])
      provisioner.create_raw_table("raw-2024-01-15")
      expect(database).to have_received(:query).with(
        a_string_starting_with("CREATE TABLE `postal-test`.`raw-2024-01-15` (`id` int(11) NOT NULL AUTO_INCREMENT, `data` longblob DEFAULT NULL, `next` int(11) DEFAULT NULL")
      )
      expect(database).to have_received(:query).with("INSERT INTO `postal-test`.`raw_message_sizes` (table_name, size) VALUES ('raw-2024-01-15', 0)")
    end

    it "ignores the table already existing" do
      allow(database).to receive(:query).and_raise(mysql_error("Table 'raw-2024-01-15' already exists"))
      expect { provisioner.create_raw_table("raw-2024-01-15") }.not_to raise_error
    end

    it "re-raises other errors" do
      allow(database).to receive(:query).and_raise(mysql_error("Table 'raw-2024-01-15' is full"))
      expect { provisioner.create_raw_table("raw-2024-01-15") }.to raise_error(Mysql2::Error, /is full/)
    end
  end

  describe "#raw_tables" do
    let(:today) { Time.now.utc.to_date }

    def stub_tables(*names)
      rows = names.map { |n| { "Tables_in_postal-test (raw-%)" => n } }
      allow(database).to receive(:query).with("SHOW TABLES FROM `postal-test` LIKE 'raw-%'").and_return(rows)
    end

    it "returns tables older than the given age, sorted" do
      old1 = "raw-#{(today - 40).strftime('%Y-%m-%d')}"
      old2 = "raw-#{(today - 31).strftime('%Y-%m-%d')}"
      recent = "raw-#{(today - 10).strftime('%Y-%m-%d')}"
      stub_tables(recent, old2, old1)
      expect(provisioner.raw_tables(30)).to eq [old1, old2]
    end

    it "excludes a table exactly at the age boundary" do
      boundary = "raw-#{(today - 30).strftime('%Y-%m-%d')}"
      stub_tables(boundary)
      expect(provisioner.raw_tables(30)).to eq []
    end

    it "returns all tables when no age is given" do
      recent = "raw-#{today.strftime('%Y-%m-%d')}"
      stub_tables(recent)
      expect(provisioner.raw_tables(nil)).to eq [recent]
    end

    it "returns an empty array when there are no tables" do
      stub_tables
      expect(provisioner.raw_tables).to eq []
    end

    it "only strips the leading raw- prefix before parsing the date" do
      stub_tables("raw-raw-2000-01-01")
      expect(provisioner.raw_tables(30)).to eq ["raw-raw-2000-01-01"]
    end

    it "raises when a table name does not contain a date" do
      stub_tables("raw-not-a-date")
      expect { provisioner.raw_tables }.to raise_error(Date::Error)
    end
  end

  describe "#remove_raw_table" do
    it "detaches messages, removes the size record and drops the table" do
      allow(database).to receive(:query).and_return([])
      provisioner.remove_raw_table("raw-2024-01-15")
      expect(database).to have_received(:query).with(
        "UPDATE `postal-test`.`messages` SET raw_table = NULL, raw_headers_id = NULL, raw_body_id = NULL, size = NULL WHERE raw_table = 'raw-2024-01-15'"
      ).ordered
      expect(database).to have_received(:query).with("DELETE FROM `postal-test`.`raw_message_sizes` WHERE table_name = 'raw-2024-01-15'").ordered
      expect(database).to have_received(:query).with("DROP TABLE `postal-test`.`raw-2024-01-15`").ordered
    end
  end

  describe "#remove_raw_tables_older_than" do
    it "removes each old table" do
      allow(provisioner).to receive(:raw_tables).with(60).and_return(["raw-2020-01-01", "raw-2020-01-02"])
      allow(provisioner).to receive(:remove_raw_table)
      provisioner.remove_raw_tables_older_than(60)
      expect(provisioner).to have_received(:remove_raw_table).with("raw-2020-01-01")
      expect(provisioner).to have_received(:remove_raw_table).with("raw-2020-01-02")
    end
  end
end
