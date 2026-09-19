# frozen_string_literal: true

require "rails_helper"

describe Postal::MessageDB::Database do
  context "when provisioned" do
    let(:server) { create(:server) }
    subject(:database) { server.message_db }

    it "should be a message db" do
      expect(database).to be_a Postal::MessageDB::Database
    end

    it "should return the current schema version" do
      expect(database.schema_version).to be_a Integer
    end

    describe "#escape_identifier" do
      it "wraps a plain identifier in backticks" do
        expect(database.send(:escape_identifier, "id")).to eq "`id`"
      end

      it "doubles embedded backticks so the value cannot break out of the quoting" do
        expect(database.send(:escape_identifier, "id`=0 OR SLEEP(5)#"))
          .to eq "`id``=0 OR SLEEP(5)#`"
      end

      it "coerces non-string identifiers to a string" do
        expect(database.send(:escape_identifier, :token)).to eq "`token`"
        expect(database.send(:escape_identifier, 123)).to eq "`123`"
      end

      it "doubles every backtick, however many there are" do
        expect(database.send(:escape_identifier, "a`b`c")).to eq "`a``b``c`"
        expect(database.send(:escape_identifier, "```")).to eq "````````"
      end

      it "leaves single quotes, semicolons and comment markers inside the quoting" do
        expect(database.send(:escape_identifier, "id'; DROP TABLE messages; --")).to eq "`id'; DROP TABLE messages; --`"
      end

      it "leaves double quotes inside the quoting" do
        expect(database.send(:escape_identifier, %(id" OR "1"="1))).to eq %(`id" OR "1"="1`)
      end

      it "leaves newlines inside the quoting" do
        expect(database.send(:escape_identifier, "id\nOR 1=1\r\n")).to eq "`id\nOR 1=1\r\n`"
      end

      it "leaves backslashes inside the quoting" do
        expect(database.send(:escape_identifier, "id\\")).to eq "`id\\`"
      end

      it "leaves unicode inside the quoting" do
        expect(database.send(:escape_identifier, "日本語")).to eq "`日本語`"
      end

      it "quotes an empty string" do
        expect(database.send(:escape_identifier, "")).to eq "``"
      end

      it "quotes nil as an empty identifier" do
        expect(database.send(:escape_identifier, nil)).to eq "``"
      end
    end

    describe "#escape" do
      it "converts booleans to 1 and 0" do
        expect(database.escape(true)).to eq "1"
        expect(database.escape(false)).to eq "0"
      end

      it "converts nil and empty strings to NULL" do
        expect(database.escape(nil)).to eq "NULL"
        expect(database.escape("")).to eq "NULL"
      end

      it "quotes strings" do
        expect(database.escape("hello")).to eq "'hello'"
        expect(database.escape(5)).to eq "'5'"
      end

      it "escapes single quotes" do
        expect(database.escape("it's")).to eq "'it\\'s'"
      end

      it "escapes double quotes and backslashes" do
        expect(database.escape(%(a"b\\c))).to eq %('a\\"b\\\\c')
      end

      it "escapes newlines and NUL bytes" do
        expect(database.escape("a\nb\r\0")).to eq "'a\\nb\\r\\0'"
      end

      it "does not treat backticks or semicolons specially" do
        expect(database.escape("`; DROP TABLE messages; --")).to eq "'`; DROP TABLE messages; --'"
      end

      it "leaves unicode intact" do
        expect(database.escape("日本語")).to eq "'日本語'"
      end
    end

    describe "#hash_to_sql" do
      it "builds a simple equality condition" do
        expect(database.send(:hash_to_sql, { "id" => 5 })).to eq "`id` = '5'"
      end

      it "builds an IN condition for an array of integers" do
        expect(database.send(:hash_to_sql, { "id" => [1, 2] })).to eq "`id` IN (1, 2)"
      end

      it "builds operator conditions for a hash value" do
        expect(database.send(:hash_to_sql, { "id" => { greater_than: 1 } }))
          .to eq "`id` > '1'"
      end

      # Regression tests for GHSA-x2hq-rfpg-3xr5: a backtick in the condition
      # key must be neutralised so it cannot close the identifier quoting and
      # inject arbitrary SQL.
      it "neutralises a backtick injection in an equality key" do
        sql = database.send(:hash_to_sql, { "id`=0 OR SLEEP(5)#" => "x" })
        expect(sql).to eq "`id``=0 OR SLEEP(5)#` = 'x'"
      end

      it "neutralises a backtick injection in an IN key" do
        sql = database.send(:hash_to_sql, { "id`)#" => %w[a b] })
        expect(sql).to eq "`id``)#` IN ('a', 'b')"
      end

      it "neutralises a backtick injection in an operator key" do
        sql = database.send(:hash_to_sql, { "id`#" => { greater_than: 1 } })
        expect(sql).to eq "`id``#` > '1'"
      end

      it "escapes the values of a non-integer array" do
        expect(database.send(:hash_to_sql, { "token" => ["a'b", "c"] })).to eq "`token` IN ('a\\'b', 'c')"
      end

      it "escapes a mixed array rather than inlining it" do
        expect(database.send(:hash_to_sql, { "id" => [1, "2"] })).to eq "`id` IN ('1', '2')"
      end

      it "escapes a value which looks like an integer injection" do
        expect(database.send(:hash_to_sql, { "id" => "1 OR 1=1" })).to eq "`id` = '1 OR 1=1'"
      end

      it "joins multiple operators with the joiner" do
        sql = database.send(:hash_to_sql, { "id" => { greater_than: 1, less_than_or_equal_to: 5 } }, " AND ")
        expect(sql).to eq "`id` > '1' AND `id` <= '5'"
      end

      it "supports every operator" do
        sql = database.send(:hash_to_sql, { "id" => { less_than: 1, greater_than_or_equal_to: 2 } })
        expect(sql).to eq "`id` < '1', `id` >= '2'"
      end

      it "produces a tautology for a hash with no known operators" do
        expect(database.send(:hash_to_sql, { "id" => { "like" => "x" } })).to eq "1=1"
      end

      it "joins multiple conditions with the joiner" do
        expect(database.send(:hash_to_sql, { "a" => 1, "b" => 2 }, " AND ")).to eq "`a` = '1' AND `b` = '2'"
      end

      it "assigns nil and booleans in a SET list" do
        expect(database.send(:hash_to_sql, { "a" => nil, "b" => true, "c" => false })).to eq "`a` = NULL, `b` = 1, `c` = 0"
      end

      it "compares nil with IS NULL in a WHERE clause" do
        expect(database.send(:build_where_string, { "a" => nil, "b" => true }, " AND ")).to eq "WHERE `a` IS NULL AND `b` = 1"
      end

      it "builds an OR group for an array containing nil" do
        expect(database.send(:build_where_string, { "tag" => ["invoices", nil] })).to eq "WHERE (`tag` = 'invoices' OR `tag` IS NULL)"
      end

      it "builds an OR group for an array containing operator hashes" do
        sql = database.send(:hash_to_sql, { "rcpt_to" => [{ starts_with: "rachel" }, "bob@example.com"] })
        expect(sql).to eq "(`rcpt_to` LIKE 'rachel%' OR `rcpt_to` = 'bob@example.com')"
      end

      it "keeps other conditions outside the OR group" do
        sql = database.send(:build_where_string, { "rcpt_to" => [{ contains: "a" }, { contains: "b" }], "spam" => false }, " AND ")
        expect(sql).to eq "WHERE (`rcpt_to` LIKE '%a%' OR `rcpt_to` LIKE '%b%') AND `spam` = 0"
      end

      it "builds a LIKE condition for a contains operator" do
        expect(database.send(:hash_to_sql, { "subject" => { contains: "invoice" } }))
          .to eq "`subject` LIKE '%invoice%'"
      end

      it "builds a LIKE condition for a starts_with operator" do
        expect(database.send(:hash_to_sql, { "rcpt_to" => { starts_with: "rachel" } }))
          .to eq "`rcpt_to` LIKE 'rachel%'"
      end

      it "builds a LIKE condition for an ends_with operator" do
        expect(database.send(:hash_to_sql, { "rcpt_to" => { ends_with: "@example.com" } }))
          .to eq "`rcpt_to` LIKE '%@example.com'"
      end

      it "escapes literal % and _ wildcards in a contains value" do
        expect(database.send(:hash_to_sql, { "subject" => { contains: "50%_off" } }))
          .to eq "`subject` LIKE '%50\\\\%\\\\_off%'"
      end

      it "escapes a literal backslash in a contains value" do
        expect(database.send(:hash_to_sql, { "subject" => { contains: 'a\\b' } }))
          .to eq "`subject` LIKE '%a\\\\\\\\b%'"
      end

      it "combines contains with other operators using the joiner" do
        sql = database.send(:hash_to_sql, { "subject" => { contains: "x", greater_than: 1 } }, " AND ")
        expect(sql).to eq "`subject` LIKE '%x%' AND `subject` > '1'"
      end
    end

    describe "#escape_like_wildcards" do
      it "escapes percent and underscore" do
        expect(database.send(:escape_like_wildcards, "50%_off")).to eq "50\\%\\_off"
      end

      it "escapes backslashes" do
        expect(database.send(:escape_like_wildcards, 'a\\b')).to eq 'a\\\\b'
      end

      it "leaves ordinary text untouched" do
        expect(database.send(:escape_like_wildcards, "hello")).to eq "hello"
      end
    end

    describe "hostile identifiers against the live database" do
      # Every identifier is treated as a single (non-existent) column or table,
      # so MySQL rejects the query instead of executing the injected SQL.
      it "does not allow SQL injection via a backtick in a condition key" do
        expect do
          database.select("messages", where: { "id`=0 OR 1=1#" => "x" }, limit: 1)
        end.to raise_error(Mysql2::Error)
      end

      it "does not allow SQL injection via a quote in a condition key" do
        expect do
          database.select("messages", where: { "id' OR '1'='1" => "x" }, limit: 1)
        end.to raise_error(Mysql2::Error)
      end

      it "does not allow SQL injection via a comment in a condition key" do
        expect do
          database.select("messages", where: { "id`; -- " => "x" }, limit: 1)
        end.to raise_error(Mysql2::Error)
      end

      it "does not allow SQL injection via a newline in a condition key" do
        expect do
          database.select("messages", where: { "id\n=0 OR 1=1" => "x" }, limit: 1)
        end.to raise_error(Mysql2::Error)
      end

      it "rejects an empty condition key" do
        expect do
          database.select("messages", where: { "" => "x" }, limit: 1)
        end.to raise_error(Mysql2::Error)
      end

      it "rejects a unicode condition key" do
        expect do
          database.select("messages", where: { "日本語" => "x" }, limit: 1)
        end.to raise_error(Mysql2::Error)
      end

      it "does not allow SQL injection via the order column" do
        expect do
          database.select("messages", order: "id` DESC; DROP TABLE messages; -- ", limit: 1)
        end.to raise_error(Mysql2::Error)
      end

      it "does not allow SQL injection via the field list" do
        expect do
          database.select("messages", fields: ["id`, (SELECT 1); -- "], limit: 1)
        end.to raise_error(Mysql2::Error)
      end

      it "does not allow SQL injection via the table name" do
        expect do
          database.select("messages` WHERE 1=1; -- ", limit: 1)
        end.to raise_error(Mysql2::Error)
      end

      it "does not allow SQL injection via an update column" do
        expect do
          database.update("messages", { "id`=1; -- " => 1 }, where: { id: 0 })
        end.to raise_error(Mysql2::Error)
      end

      it "does not allow SQL injection via an insert column" do
        expect do
          database.insert("messages", { "id`) VALUES (1); -- " => 1 })
        end.to raise_error(Mysql2::Error)
      end

      it "does not allow SQL injection via a multi-insert column" do
        expect do
          database.insert_multi("messages", ["id`) VALUES (1); -- "], [[1]])
        end.to raise_error(Mysql2::Error)
      end

      it "does not allow SQL injection via a delete condition key" do
        expect do
          database.delete("messages", where: { "id`=0 OR 1=1; -- " => 1 })
        end.to raise_error(Mysql2::Error)
      end

      it "does not allow SQL injection via a raw message table name" do
        expect do
          database.insert("raw-2024-01-15`; DROP TABLE messages; -- ", data: "x")
        end.to raise_error(Mysql2::Error)
      end

      it "still accepts legitimate identifiers" do
        expect(database.select("messages", where: { "id" => 0 }, order: :id, direction: "desc", fields: [:id, :token], limit: 1)).to eq []
      end
    end

    describe "#select" do
      it "rejects an invalid direction" do
        expect { database.select("messages", order: :id, direction: "sideways") }.to raise_error(Postal::Error, /Invalid direction sideways/)
      end

      it "rejects a direction containing SQL" do
        expect { database.select("messages", order: :id, direction: "ASC; DROP TABLE messages") }.to raise_error(Postal::Error, /Invalid direction/)
      end

      it "accepts a lower case direction" do
        expect(database.select("messages", order: :id, direction: "desc", limit: 1)).to be_an Array
      end

      it "returns a count when requested" do
        expect(database.select("messages", count: true)).to be_an Integer
      end
    end

    describe "#database_name" do
      it "derives the name from the prefix and server ID" do
        expect(described_class.new(1, 42).database_name).to eq "#{Postal::Config.message_db.database_name_prefix}-server-42"
      end

      it "uses an explicit database name when given" do
        expect(described_class.new(1, 42, database_name: "custom").database_name).to eq "custom"
      end
    end

    describe "#raw_table_name_for_date" do
      it "formats the date" do
        expect(database.raw_table_name_for_date(Date.new(2024, 1, 5))).to eq "raw-2024-01-05"
      end
    end

    describe "#insert_raw_message" do
      let(:date) { Date.new(2024, 1, 15) }

      before do
        allow(database).to receive(:insert).and_return(11, 22)
      end

      it "splits the headers from the body on the first CRLF CRLF" do
        result = database.insert_raw_message("Subject: x\r\nTo: y\r\n\r\nbody\r\n\r\nmore", date)
        expect(result).to eq ["raw-2024-01-15", 11, 22]
        expect(database).to have_received(:insert).with("raw-2024-01-15", data: "Subject: x\r\nTo: y").ordered
        expect(database).to have_received(:insert).with("raw-2024-01-15", data: "body\r\n\r\nmore").ordered
      end

      it "splits on LF LF" do
        database.insert_raw_message("Subject: x\nTo: y\n\nbody\n\nmore", date)
        expect(database).to have_received(:insert).with("raw-2024-01-15", data: "Subject: x\nTo: y")
        expect(database).to have_received(:insert).with("raw-2024-01-15", data: "body\n\nmore")
      end

      it "splits on mixed line endings" do
        database.insert_raw_message("Subject: x\r\n\nbody", date)
        expect(database).to have_received(:insert).with("raw-2024-01-15", data: "Subject: x")
        expect(database).to have_received(:insert).with("raw-2024-01-15", data: "body")

        database.insert_raw_message("Subject: y\n\r\nbody", date)
        expect(database).to have_received(:insert).with("raw-2024-01-15", data: "Subject: y")
      end

      it "does not split on a bare CR CR" do
        database.insert_raw_message("Subject: x\r\rbody", date)
        expect(database).to have_received(:insert).with("raw-2024-01-15", data: "Subject: x\r\rbody")
        expect(database).to have_received(:insert).with("raw-2024-01-15", data: nil)
      end

      it "stores a nil body when there is no blank line" do
        database.insert_raw_message("Subject: x\r\nTo: y", date)
        expect(database).to have_received(:insert).with("raw-2024-01-15", data: "Subject: x\r\nTo: y")
        expect(database).to have_received(:insert).with("raw-2024-01-15", data: nil)
      end

      it "stores empty headers when the message starts with a blank line" do
        database.insert_raw_message("\r\n\r\nbody", date)
        expect(database).to have_received(:insert).with("raw-2024-01-15", data: "")
        expect(database).to have_received(:insert).with("raw-2024-01-15", data: "body")
      end

      it "creates the raw table and retries when it does not exist" do
        calls = 0
        allow(database).to receive(:insert) do
          calls += 1
          raise Mysql2::Error, "Table 'postal-test.raw-2024-01-15' doesn't exist" if calls == 1

          calls
        end
        allow(database.provisioner).to receive(:create_raw_table)
        expect(database.insert_raw_message("H: 1\r\n\r\nbody", date)).to eq ["raw-2024-01-15", 2, 3]
        expect(database.provisioner).to have_received(:create_raw_table).with("raw-2024-01-15").once
      end

      it "re-raises other errors" do
        allow(database).to receive(:insert).and_raise(Mysql2::Error, "Table 'raw-2024-01-15' is full")
        expect { database.insert_raw_message("H: 1\r\n\r\nbody", date) }.to raise_error(Mysql2::Error, /is full/)
      end
    end

    describe "#schema_version" do
      it "returns 0 when the migrations table does not exist" do
        db = described_class.new(1, 42, database_name: "postal-test-missing")
        allow(db).to receive(:select).and_raise(Mysql2::Error, "Table 'postal-test-missing.migrations' doesn't exist")
        expect(db.schema_version).to eq 0
      end

      it "re-raises other errors" do
        db = described_class.new(1, 42, database_name: "postal-test-missing")
        allow(db).to receive(:select).and_raise(Mysql2::Error, "Access denied")
        expect { db.schema_version }.to raise_error(Mysql2::Error, /Access denied/)
      end
    end

    describe "slow query explaining" do
      let(:connection) { double("connection") }

      after do
        Timecop.return
      end

      def run_slow(sql)
        allow(connection).to receive(:query) do
          Timecop.travel(1.second.from_now)
          []
        end
        database.send(:query_on_connection, connection, sql)
      end

      def run_fast(sql)
        allow(connection).to receive(:query).and_return([])
        database.send(:query_on_connection, connection, sql)
      end

      it "explains slow SELECT queries" do
        run_slow("SELECT * FROM `x`")
        expect(connection).to have_received(:query).with("EXPLAIN SELECT * FROM `x`")
      end

      it "explains slow UPDATE and DELETE queries" do
        run_slow("UPDATE `x` SET a = 1")
        expect(connection).to have_received(:query).with("EXPLAIN UPDATE `x` SET a = 1")
        run_slow("DELETE FROM `x`")
        expect(connection).to have_received(:query).with("EXPLAIN DELETE FROM `x`")
      end

      it "does not explain fast queries" do
        run_fast("SELECT * FROM `x`")
        expect(connection).not_to have_received(:query).with(/\AEXPLAIN /)
      end

      it "does not explain INSERT or SHOW queries" do
        run_slow("INSERT INTO `x` (a) VALUES (1)")
        run_slow("SHOW TABLES")
        expect(connection).not_to have_received(:query).with(/\AEXPLAIN /)
      end

      it "does not explain lower case or indented queries" do
        run_slow("select * from `x`")
        run_slow(" SELECT * FROM `x`")
        run_slow("SELECT\n* FROM `x`")
        expect(connection).not_to have_received(:query).with(/\AEXPLAIN /)
      end
    end
  end
end
