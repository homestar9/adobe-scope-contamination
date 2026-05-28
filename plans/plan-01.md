\# Quick ORM Metadata Cache Corruption Reproduction Plan



\*\*For:\*\* Adobe Support (ColdFusion Concurrency Issue)  

\*\*Issue:\*\* Quick ORM's metadata cache occasionally gets polluted with another entity's data under concurrent load, causing relationship queries to reference the wrong database table.



\---



\## Problem Statement



Under concurrent class loading / entity instantiation in Adobe ColdFusion 2023, the `getMetadata()` and `getInheritedMetadata()` functions can return shared/aliased struct references. When multiple entities are being inspected for metadata simultaneously, one entity's metadata struct can overwrite another's in the shared `quickMeta` cache.



\*\*Production Symptom:\*\*

\- Endpoint: `GET /api/v1/subscriptions/?licenseNumber=868757\&licenseState=CA`

\- Expected SQL: `FROM \[notification]` (in the `withCount("notifications")` subselect)

\- Actual SQL: `FROM \[user]` (wrong entity's table)

\- Result: The foreign key constraint fails and the query errors



\*\*Root Cause Theory:\*\*

Adobe ColdFusion's `getMetadata()` / `getInheritedMetadata()` functions hand back shared/aliased metadata structs under high concurrency. If two entities inspect metadata simultaneously, the cached value for one mapping can end up holding another entity's metadata.



\---



\## Minimal Reproduction Repository Setup



\### Goal

Create a \*\*super minimal ColdBox + Quick app\*\* with:

1\. Two simple entities (e.g., `User` and `Post`)

2\. A relationship between them (e.g., `Post hasMany Comment`)

3\. A simple REST endpoint that uses `withCount()` to trigger the bug

4\. Load-testing instructions to hammer concurrent requests



\### Step 1: Create the skeleton



```bash

mkdir quick-metadata-repro

cd quick-metadata-repro

box init

```



Answer the prompts (ColdBox app, Adobe CF 2023).



\### Step 2: Key files to create



\#### `box.json` dependencies

Ensure you have:

```json

{

&#x20;   "dependencies": {

&#x20;       "coldbox": "^8.1.0",

&#x20;       "quick": "^12.0.0",

&#x20;       "qb": "^10.0.0",

&#x20;       "mementifier": "^4.0.0"

&#x20;   }

}

```



\#### `models/User.cfc` — First entity

```cfml

component extends="quick.models.BaseEntity" accessors="true" table="user" {

&#x20;   property name="id" sqltype="integer";

&#x20;   property name="name" sqltype="varchar";

&#x20;   

&#x20;   function posts() {

&#x20;       return hasMany( "Post", "userId" );

&#x20;   }

}

```



\#### `models/Post.cfc` — Second entity

```cfml

component extends="quick.models.BaseEntity" accessors="true" table="post" {

&#x20;   property name="id" sqltype="integer";

&#x20;   property name="name" sqltype="varchar";

&#x20;   property name="userId" sqltype="integer";

&#x20;   

&#x20;   function comments() {

&#x20;       return hasMany( "Comment", "postId" );

&#x20;   }

}

```



\#### `models/Comment.cfc` — Third entity (the one that gets polluted)

```cfml

component extends="quick.models.BaseEntity" accessors="true" table="comment" {

&#x20;   property name="id" sqltype="integer";

&#x20;   property name="text" sqltype="varchar";

&#x20;   property name="postId" sqltype="integer";

}

```



\*\*Key point:\*\* The `Comment` table name must be distinct from `User` and `Post` so that if the wrong metadata is cached, the SQL will visibly use the wrong table.



\#### `handlers/Test.cfc` — Endpoint that triggers withCount

```cfml

component extends="coldbox.system.RestHandler" {



&#x20;   function index( event, rc, prc ) {

&#x20;       // This withCount() call will trigger the metadata inspection

&#x20;       // for Comment. Under concurrent load, it might pick up User's

&#x20;       // or Post's cached metadata instead.

&#x20;       var posts = getInstance( "Post" )

&#x20;           .withCount( "comments" )

&#x20;           .get();

&#x20;       

&#x20;       return posts.map( p => p.getMemento() );

&#x20;   }



&#x20;   function userPosts( event, rc, prc ) {

&#x20;       // Alternative endpoint that also triggers metadata lookups

&#x20;       var users = getInstance( "User" )

&#x20;           .withCount( "posts" )

&#x20;           .get();

&#x20;       

&#x20;       return users.map( u => u.getMemento() );

&#x20;   }



}

```



\#### `config/Router.cfc`

```cfml

component extends="coldbox.system.routing.Router" {



&#x20;   function configure() {

&#x20;       route( "/test" ).to( "test.index" );

&#x20;       route( "/user-posts" ).to( "test.userPosts" );

&#x20;   }



}

```



\#### `config/CacheBox.cfc`

Ensure the `quickMeta` cache is present (Quick module sets it up by default):

```cfml

component {



&#x20;   function configure() {

&#x20;       cacheBox = {

&#x20;           // ... other caches ...

&#x20;           quickMeta = {

&#x20;               name = "quickMeta",

&#x20;               provider = "coldbox.system.cache.providers.CacheBoxColdBoxProvider",

&#x20;               properties = {

&#x20;                   objectDefaultTimeout = 0,  // No TTL — pollution sticks

&#x20;                   useLastAccessTimeouts = false,

&#x20;                   maxObjects = 300,

&#x20;                   objectStore = "ConcurrentStore"

&#x20;               }

&#x20;           }

&#x20;       };

&#x20;   }



}

```



\### Step 3: Database setup (H2 in-memory for simplicity)



Use an in-memory H2 database. Create `resources/bootstrap.sql`:

```sql

CREATE TABLE user (

&#x20;   id INT PRIMARY KEY AUTO\_INCREMENT,

&#x20;   name VARCHAR(255) NOT NULL

);



CREATE TABLE post (

&#x20;   id INT PRIMARY KEY AUTO\_INCREMENT,

&#x20;   name VARCHAR(255) NOT NULL,

&#x20;   userId INT NOT NULL,

&#x20;   FOREIGN KEY (userId) REFERENCES user(id)

);



CREATE TABLE comment (

&#x20;   id INT PRIMARY KEY AUTO\_INCREMENT,

&#x20;   text VARCHAR(255) NOT NULL,

&#x20;   postId INT NOT NULL,

&#x20;   FOREIGN KEY (postId) REFERENCES post(id)

);



INSERT INTO user (name) VALUES ('Alice'), ('Bob');

INSERT INTO post (name, userId) VALUES ('Post 1', 1), ('Post 2', 1), ('Post 3', 2);

INSERT INTO comment (text, postId) VALUES ('Great!', 1), ('Nice!', 1), ('Thanks', 2);

```



Wire up the datasource in `Application.cfc` or `config/Coldbox.cfc`.



\---



\## Load Testing to Trigger the Issue



The bug only manifests under \*\*concurrent metadata inspection\*\*. You need to hammer the endpoints with many simultaneous requests, ideally \*\*each in its own session/thread\*\*.



\### Recommended Tool: Apache JMeter or WRK



\#### Option 1: Using `wrk` (simplest)

```bash

\# Each -c (connection) should ideally be a separate session

wrk -t12 -c1000 -d60s --latency http://localhost:8080/test

```



This fires 1000 concurrent connections for 60 seconds. The high concurrency increases the chance of hitting the metadata race condition.



\#### Option 2: Using Apache JMeter

1\. Create a Test Plan with:

&#x20;  - Thread Group: 100 threads, ramp-up 10 seconds, loop count 100

&#x20;  - HTTP Request: GET `http://localhost:8080/test`

&#x20;  - Set each thread to use a \*\*separate session cookie\*\* (or none) to maximize uniqueness



2\. Add a \*\*View Results Tree\*\* listener to watch for SQL errors



3\. Run the test for 5–10 minutes



\#### Option 3: Using Apache Bench (simplest for quick tests)

```bash

ab -n 10000 -c 100 http://localhost:8080/test

```



\---



\## How to Verify the Issue



Once you trigger it (likely within the first few minutes of load testing), you should see:



\### 1. \*\*SQL Error in CF logs\*\* (inspect `\[CF\_HOME]/logs/`)

```

Syntax error in SQL statement "...FROM \[user] WHERE (...)" 

```

or

```

Column \[postId] not found in table \[user]

```



The error will appear because the `withCount("comments")` subselect is using `\[user]` table instead of `\[comment]`, but the WHERE clause references `\[postId]` (which exists in `comment`, not `user`).



\### 2. \*\*Watch the `quickMeta` cache\*\* (optional, if instrumentation added)

If you add logging to `BaseEntity.metadataInspection()`, you can see:

```

DEBUG: Cache produced entityName=Comment, table=user  ← WRONG!

```



\### 3. \*\*Correlate with thread/session info\*\*

The error should occur during a burst of concurrent requests. Single-threaded or slow sequential requests will NOT trigger the issue.



\---



\## Expected Outcome



If Adobe ColdFusion's `getMetadata()` truly returns shared/aliased structs under concurrency:

\- \*\*Within 1–5 minutes\*\* of load testing, you should see at least one SQL error with a mismatch (e.g., wrong table name)

\- Restarting the app clears the cache and the issue temporarily disappears

\- Re-running the load test makes it reappear



If no errors occur after 10+ minutes of heavy concurrency:

\- The issue may be specific to the CCIS codebase's complexity / specific entity configs

\- Or it may require a particular version of CF 2023 that has been patched



\---



\## Instrumentation to Add (Optional, for Adobe Support)



If you want to capture raw evidence, patch `BaseEntity.metadataInspection()`:



```cfml

// Inside the getOrSet closure, after line 2835 (\~):

if ( lcase( meta.entityName ) != lcase( expectedEntityName ) ) {

&#x20;   var logMsg = "METADATA\_CORRUPTION: mapping=\[#variables.\_mapping#], " \&

&#x20;       "expected=\[#expectedEntityName#], got=\[#meta.entityName#], table=\[#meta.table#]";

&#x20;   

&#x20;   // Write to a dedicated corruption log

&#x20;   fileAppend( expandPath( "/logs/metadata-corruption.log" ), 

&#x20;              now() \& ": " \& logMsg \& chr(10) );

&#x20;   

&#x20;   // Also throw so CF logs capture the call stack

&#x20;   throw type="MetadataCorruptionDetected" message=logMsg;

}

```



This ensures every corruption event is timestamped and logged, giving Adobe direct evidence of when/how the race happens.



\---



\## Shipping the Repository



Create the repo with this structure:



```

quick-metadata-repro/

├── README.md                          (instructions below)

├── REPRO\_PLAN.md                      (this file)

├── Application.cfc

├── box.json

├── config/

│   ├── CacheBox.cfc

│   ├── Coldbox.cfc

│   ├── Router.cfc

│   └── WireBox.cfc

├── handlers/

│   └── Test.cfc

├── models/

│   ├── User.cfc

│   ├── Post.cfc

│   └── Comment.cfc

├── resources/

│   └── bootstrap.sql

└── tests/

&#x20;   └── (optional: basic unit tests)

```



\### README.md Content



```markdown

\# Quick ORM Metadata Cache Corruption Reproduction



This is a \*\*minimal, reproducible test case\*\* for Adobe ColdFusion's metadata concurrency issue with Quick ORM.



\## Quick Start



1\. \*\*Install dependencies:\*\*

&#x20;  ```bash

&#x20;  box install

&#x20;  ```



2\. \*\*Start the server:\*\*

&#x20;  ```bash

&#x20;  box server start

&#x20;  ```



3\. \*\*Run the load test\*\* (requires `wrk` or `ab`):

&#x20;  ```bash

&#x20;  wrk -t12 -c1000 -d60s --latency http://localhost:8080/test

&#x20;  ```



4\. \*\*Watch for SQL errors\*\* in the CF console or `\[CF\_HOME]/logs/`.



\## What Should Happen



Under heavy concurrent load (1000+ simultaneous connections), the `withCount()` call will occasionally pick up the wrong entity's cached metadata, causing SQL queries to reference the wrong table. You should see errors like:



```

Column \[postId] not found in table \[user]

```



This happens because the `Comment` entity's metadata was cached with `table=user` instead of `table=comment`.



\## Endpoints



\- `GET /test` — Triggers `Post.withCount("comments")`

\- `GET /user-posts` — Triggers `User.withCount("posts")`



\## Root Cause



Adobe ColdFusion's `getMetadata()` / `getInheritedMetadata()` can return shared/aliased struct references under concurrent class inspection, polluting Quick ORM's per-mapping cache entry.



\## References



\- \[Quick ORM Documentation](https://quick.ortusbooks.com)

\- \[Adobe ColdFusion Metadata API](https://helpx.adobe.com/coldfusion/developing-applications/the-cfml-programming-language/using-objects/using-metadata.html)

```



\---



\## Summary for Adobe Support



\*\*Email to Adobe:\*\*



> We've encountered a production issue where Quick ORM's metadata cache occasionally gets polluted under concurrent load, causing relationship queries to use the wrong table. We suspect it's related to Adobe ColdFusion's `getMetadata()` / `getInheritedMetadata()` functions returning shared/aliased struct references during concurrent class inspection.

>

> We've created a minimal reproduction repository (attached) that:

> 1. Uses ColdBox + Quick ORM

> 2. Exposes endpoints that trigger `withCount()` calls

> 3. Includes load-test instructions to hammer concurrent requests

>

> Expected result: SQL errors with table name mismatches within 1–5 minutes of load testing.

>

> If you can trigger and capture the error, we can work together to identify the root cause and implement a fix in Quick ORM or Adobe ColdFusion.



\---



\## Notes for Implementation



\- Keep the repo \*\*under 50MB\*\* (no node\_modules, no jars)

\- Use \*\*H2 in-memory database\*\* for zero setup

\- Include \*\*clear, copy-paste load-test commands\*\* so Adobe doesn't have to think

\- Document \*\*exactly what error to look for\*\* so Adobe knows success when they see it

\- Consider adding a \*\*metrics endpoint\*\* that logs/exposes the current `quickMeta` cache contents (useful for debugging)



Good luck with Adobe Support!



