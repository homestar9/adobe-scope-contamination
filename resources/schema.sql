/* =====================================================================
   Adobe ColdFusion 2023 — Quick ORM scope-contamination reproduction
   SQL Server schema + seed data.

   Two INDEPENDENT parent/child pairs. The child tables deliberately use
   DIFFERENTLY-NAMED foreign-key columns:

       alpha_child.alpha_parent_id
       bravo_child.bravo_parent_id

   This is the key to making contamination self-evident: if a transient
   QueryBuilder's table name is contaminated across concurrent requests,
   an UPDATE meant for [alpha_child] will instead target [bravo_child]
   (or vice-versa) while still SETting the *original* FK column. Because
   [bravo_child] has no [alpha_parent_id] column, SQL Server throws
   "Invalid column name 'alpha_parent_id'" — exactly mirroring the
   production failure where [user_type] had no [remoteAppId] column.

   Run once against your (empty) "adobe-temp" datasource. Re-runnable.
   ===================================================================== */

IF OBJECT_ID('dbo.alpha_child', 'U')  IS NOT NULL DROP TABLE dbo.alpha_child;
IF OBJECT_ID('dbo.alpha_parent', 'U') IS NOT NULL DROP TABLE dbo.alpha_parent;
IF OBJECT_ID('dbo.bravo_child', 'U')  IS NOT NULL DROP TABLE dbo.bravo_child;
IF OBJECT_ID('dbo.bravo_parent', 'U') IS NOT NULL DROP TABLE dbo.bravo_parent;

CREATE TABLE dbo.alpha_parent (
    id   INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    name VARCHAR(255) NOT NULL
);

CREATE TABLE dbo.alpha_child (
    id              INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    name            VARCHAR(255) NOT NULL,
    alpha_parent_id INT NULL
);

CREATE TABLE dbo.bravo_parent (
    id   INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    name VARCHAR(255) NOT NULL
);

CREATE TABLE dbo.bravo_child (
    id              INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    name            VARCHAR(255) NOT NULL,
    bravo_parent_id INT NULL
);

/* ----- seed: one parent per pair, with a few related children ----- */

INSERT INTO dbo.alpha_parent (name) VALUES ('Alpha Parent 1');
INSERT INTO dbo.bravo_parent (name) VALUES ('Bravo Parent 1');

INSERT INTO dbo.alpha_child (name, alpha_parent_id) VALUES
    ('Alpha Child A', 1), ('Alpha Child B', 1), ('Alpha Child C', 1);

INSERT INTO dbo.bravo_child (name, bravo_parent_id) VALUES
    ('Bravo Child A', 1), ('Bravo Child B', 1), ('Bravo Child C', 1);
