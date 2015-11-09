#!/usr/bin/env perl
# Copyright 2015 Frank Breedijk
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ------------------------------------------------------------------------------
# This little script checks all files te see if they are perl files and if so 
# ------------------------------------------------------------------------------

use strict;
use Test::More;
use Algorithm::Diff qw( diff );
use Data::Dumper;
use DBI;
use DBD::mysql;
use DBD::Pg;

my $tests = 0;
my $out = "";

if (`hostname` =~ /^sbpd/) {
	ok("Skipping these tests on the final build system");
	$tests++;
} else {

	my $version = 0;
	foreach my $data_file (<db/data_v*.mysql>) {
		$data_file =~ /^db\/data_v(\d+)\.mysql$/;
		$version = $1 if $1 > $version;
	}
	
	cmp_ok($version, ">", 0, "Highest DB version = $version");
	$tests++;

	print `mysql -uroot -e "drop database seccubus"`;
	print `mysql -uroot -e "create database seccubus"`;
	ok(1,"Created empty mysql DB"); $tests++;

	`mysql -uroot seccubus < db/structure_v$version.mysql`;
	`mysql -uroot seccubus < db/data_v$version.mysql`;
	ok(1,"Mysql database content v$version created"); $tests++;

	$out = `dropdb seccubus`;
	is($out,"","Pg DB dropped"); $tests++;
	$out = `createdb seccubus`;
	is($out,"","Pg DB created"); $tests++;
	$out = `echo "alter database seccubus owner to postgres;" |  psql`;
	is($out,"ALTER DATABASE\n","DB owned by postgres"); $tests++;
	$out = `echo "create role seccubus;" |  psql`;
	$out =~ s/CREATE ROLE\n//;
	is($out,"","seccubus role created"); $tests++;
	$out = `echo "grant seccubus to postgres;" |  psql`;
	is($out,"GRANT ROLE\n","postgres member of seccubus"); $tests++;

	$out = `psql -U postgres seccubus < db/structure_v$version.psql 2>&1`;
	$out =~ s/(SET|GRANT|REVOKE|(CREATE|ALTER) (FUNCTION|TABLE|SEQUENCE|INDEX|TRIGGER|LANGUAGE))\n//g;
	$out =~ s/ERROR:  language "plpgsql" already exists\n//g;
	$out =~ s/ERROR:  must be owner of language plpgsql\n//g;
	$out =~ s/WARNING:  no privileges could be revoked for "public"\n//g;
	$out =~ s/WARNING:  no privileges were granted for "public"\n//g;
	is($out,"","Pg DB structure created"); $tests++;
	$out = `psql -U postgres seccubus < db/data_v$version.psql 2>&1`;
	$out =~ s/(\-+|SET|(COPY)*\s+\d+|\s+setval\s*|\(\d+ row\))\n//g;
	is($out,"\n","Pg DB content created"); $tests++;

	my $mysql = DBI->connect_cached("DBI:mysql:database=seccubus","root","");
	ok($mysql,"Got mysql DBI handle"); $tests++;

	my $pg = DBI->connect_cached("DBI:Pg:dbname=seccubus","postgres","");
	ok($pg,"Got postgress DBI handle"); $tests++;

	# Lets get all tables
	my $msth = $mysql->prepare("show tables;");
	$msth->execute();
	my $mtables = $msth->fetchall_arrayref();

	my $psth = $pg->prepare("SELECT table_name FROM information_schema.tables WHERE table_schema = 'public'; -- \\d");
	$psth->execute();
	my $ptables = $psth->fetchall_arrayref();
	
	# Results should be the same
	is_deeply($msth,$psth,"Both database have the same tables"); $tests++;

	# Cycle through all tables
	foreach my $table ( @$mtables ) {
		#die Dumper $$table[0];

		$msth = $mysql->prepare("describe $$table[0]");
		$msth->execute();
		my $mtable = $msth->fetchall_arrayref();
=pod
Example
+----------+---------+------+-----+---------+----------------+
| Field    | Type    | Null | Key | Default | Extra          |
+----------+---------+------+-----+---------+----------------+
| id       | int(11) | NO   | PRI | NULL    | auto_increment |
| asset_id | int(11) | NO   |     | NULL    |                |
| scan_id  | int(11) | NO   | MUL | NULL    |                |
+----------+---------+------+-----+---------+----------------+
3 rows in set (0.04 sec)
=cut
		$psth = $pg->prepare("
			SELECT  
			    f.attnum AS number,  
			    f.attname AS name,  
			    f.attnum,  
			    f.attnotnull AS notnull,  
			    pg_catalog.format_type(f.atttypid,f.atttypmod) AS type,  
			    CASE  
			        WHEN p.contype = 'p' THEN 't'  
			        ELSE 'f'  
			    END AS primarykey,  
			    CASE  
			        WHEN p.contype = 'u' THEN 't'  
			        ELSE 'f'
			    END AS uniquekey,
			    CASE
			        WHEN p.contype = 'f' THEN g.relname
			    END AS foreignkey,
			    CASE
			        WHEN p.contype = 'f' THEN p.confkey
			    END AS foreignkey_fieldnum,
			    CASE
			        WHEN p.contype = 'f' THEN g.relname
			    END AS foreignkey,
			    CASE
			        WHEN p.contype = 'f' THEN p.conkey
			    END AS foreignkey_connnum,
			    CASE
			        WHEN f.atthasdef = 't' THEN d.adsrc
			    END AS default
			FROM pg_attribute f  
			    JOIN pg_class c ON c.oid = f.attrelid  
			    JOIN pg_type t ON t.oid = f.atttypid  
			    LEFT JOIN pg_attrdef d ON d.adrelid = c.oid AND d.adnum = f.attnum  
			    LEFT JOIN pg_namespace n ON n.oid = c.relnamespace  
			    LEFT JOIN pg_constraint p ON p.conrelid = c.oid AND f.attnum = ANY (p.conkey)  
			    LEFT JOIN pg_class AS g ON p.confrelid = g.oid  
			WHERE c.relkind = 'r'::char  
			    AND n.nspname = 'public'  -- Replace with Schema name  
			    AND c.relname = '$$table[0]'  -- Replace with table name  
			    AND f.attnum > 0 ORDER BY number
			"
		);
		$psth->execute();
		my $ptable = $psth->fetchall_arrayref();
=pod
Example output

 number |   name   | attnum | notnull |  type  | primarykey | uniquekey | foreignkey | foreignkey_fieldnum | foreignkey | foreignkey_connnum | default
--------+----------+--------+---------+--------+------------+-----------+------------+---------------------+------------+--------------------+---------
      1 | id       |      1 | t       | bigint | t          | f         |            |                     |            |                    |
      2 | asset_id |      2 | t       | bigint | f          | f         |            |                     |            |                    |
      3 | scan_id  |      3 | t       | bigint | f          | f         | assets     | {1}                 | assets     | {3}                |
      3 | scan_id  |      3 | t       | bigint | f          | f         | scans      | {1}                 | scans      | {3}                |
(4 rows)

Row 3 is repeated, because it is a a multi-foreigh key (it shouldn't be BTW)
=cut      
		my $p=0;
		my $r=0;
		foreach my $row ( @$mtable ) { # Iterate through mysql table
			$r++;
			my $prow = $$ptable[$p];

			# Name
			is($$row[0],$$prow[1],"Column name $$table[0]:$$row[0] equal"); $tests++;

			# Data type
			$$prow[4] =~ s/^character varying/varchar/;
			$$row[1] =~ s/^longtext$/text/;
			$$prow[4] =~ s/^timestamp without time zone$/timestamp/;
			$$row[1] =~ s/^longblob$/bytea/;
			$$row[1] =~ s/^(tiny)?int\(1\)$/smallint/;
			if ( $$row[1] eq "int(11)" && $$prow[4] eq "bigint" ) {
				pass("Data types are equal"); $tests++;
			} elsif ( $$row[1] =~ /^char\((\d+)\)/ ) {
				is($$prow[4], "varchar($1)", "Data types are equal"); $tests++;
			} else {
				is($$row[1],$$prow[4],"Data types are equal"); $tests++;
			}
			
			# Null constraint
			if ( $$row[2] eq "NO" ) {
				is($$prow[3],1,"Null constraint set to not null"); $tests++;	
			} elsif ( $$row[2] eq "YES" ) {
				is($$prow[3],0,"Null constraint not set to not null"); $tests++;	
			} else {
				fail("Unkown null constraint $$row[3]"); $tests++;
			}

			# Key type
			if ( $$row[3] eq "PRI" ) {
				is($$prow[5],"t","Correctly set as primary key"); $tests++;
			} elsif ( $$row[3] eq "MUL" ) {
				isnt($$prow[7],"","Correctly set as foreign key"); $tests++;
			} elsif ( $$row[3] eq "UNI" ) {
				isnt($$prow[6],"t","Correctly set as unique"); $tests++;
			} elsif ( $$row[3] eq "" ) {
				# Do nothing
			} else {
				fail("Unknow key type $$row[3]");
			}

			while($$ptable[$p][0] == $$ptable[$p+1][0] ) {
				$p++;
			}
			$p++;
			#die Dumper $row;
			#die Dumper $prow;
		}
		is($p+1,@$ptable,"All rows inspected"); $tests++;
		#die Dumper $ptable;
	}


}

done_testing($tests);
