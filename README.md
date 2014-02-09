mysql-snitch
============

mysql-snitch is a tool to watch tables/queries for any changes and tattle if
they do with details of the records that changed.  Basically, a very, very
simple MySQL Intrusion Detection System that's easy to apply to either your own
or a third party application using a MySQL backend.

Quick Start
===========

    $ git clone
    $ cd mysql-snitch
    $ npm install

    # Set up your configs - look at the Configuration section below
    $ cp config/example.yaml config/production.yaml
    $ vim config/production.yaml

    $ NODE_ENV=production coffee run.coffee

Configuration
=============

mysql-snitch uses the lovely [`config`][config] module so it's easy to create
configs based on hosts or general environments.

By default, I use YAML for the configuration so all examples will be in that
format.  If you wish, you can use JSON or actual JavaScript code for your
configs (with the exception that runtime.json MUST be JSON).

The [example config][example config] in the repo provides information on what can
be done.

[config]: https://github.com/lorenwest/node-config
[example config]: /config/example.yaml

Example Queries
===============

*vBulletin*

`SELECT * FROM administrator` - Notify of new admins, deleted admins, or admin
permission changes.

`SELECT * FROM plugin` - Notify of any changes to VB plugins

`SELECT * FROM template` - Notify of any change to VB templates

You can get fancy and use joins to make the notifications a bit more useful:

    SELECT
      u.userid,
      u.username,
      a.adminpermissions,
      a.notes,
      u.password,
      u.salt,
      u.email
    FROM
      administrator a
      JOIN user u ON a.userid = u.userid
    ORDER BY u.userid ASC

This detects changes to an admin's username, permissions, password, salt, or
email.  It will also detect new or removed admins.

*Drupal*

New/Deleted/Changed Admins:

    SELECT
      u.uid,
      u.name,
      u.pass,
      u.mail,
      u.status
    FROM
      users u
      JOIN users_roles ur ON u.uid = ur.uid
      JOIN role r ON ur.rid = r.rid
    WHERE
      r.name = 'administrator'
    ORDER BY u.uid ASC


Technical Notes
===============

* Snitch does not use long-running connections to the database.  It creates and
  ends the connection for every check to avoid dealing with timeouts.
* Records are compared based on a field named 'id' or the first field returned
  by the query.  You can alias any field to the name 'id' to force it to be the
  ID field used for comparison.
