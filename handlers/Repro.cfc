/**
 * Repro — endpoints that reproduce the ACF 2023 scope-contamination bug along
 * the EXACT production code path:
 *
 *   entity.setXChildren( [...] )
 *     -> BaseEntity.tryRelationshipSetter()
 *       -> HasOneOrMany.applySetter()
 *         -> QuickBuilder.updateAll( force = true )
 *           -> QuickQB.update()  =>  UPDATE [x_child] SET [x_parent_id] = NULL WHERE ...
 *
 * Each request resolves FRESH transient entities via WireBox getInstance(), then
 * re-asserts the parent's children (null all FKs, then re-associate the same rows)
 * so the production UPDATE statement fires on every request while leaving the data
 * stable for sustained load testing.
 *
 * Detection happens in two places:
 *   1. interceptors/ContaminationDetector.cfc  (preQBExecute — proactive, logged)
 *   2. the try/catch below                      (the SQL Server error, like prod)
 */
component extends="coldbox.system.RestHandler" {

	// GET /repro/alpha
	function alpha( event, rc, prc ) {
		return runRepro( event, "AlphaParent", "AlphaChild", "alphaChildren", "alpha_child" );
	}

	// GET /repro/bravo
	function bravo( event, rc, prc ) {
		return runRepro( event, "BravoParent", "BravoChild", "bravoChildren", "bravo_child" );
	}

	/**
	 * GET /repro/wire
	 *
	 * Contamination probe WITHOUT Quick and WITHOUT a shared base class. Each request builds six
	 * unrelated transients (models/wire/WireProbeA..F) through WireBox, each with a per-request
	 * token passed as a constructor argument, plus injected and nested WireHelper transients that
	 * record the token. Then it checks that every value in every instance belongs to this request.
	 * A mismatch is logged as WIRE_CROSSING in logs/contamination_log.txt and returns HTTP 500.
	 *
	 * Why: Adobe's v3 hotfix locks per class and per ancestor. The Quick workload (/repro/alpha +
	 * /repro/bravo) only ever constructs classes that share BaseEntity and QuickQB locks, so it
	 * cannot tell whether v3 protects constructions that share no lock. This one can.
	 */
	function wire( event, rc, prc ) {
		var token    = createUUID();
		var problems = [];
		try {
			for ( var k in [ "A", "B", "C", "D", "E", "F" ] ) {
				var expected = token & "-" & k;
				var probe    = getInstance( name = "models.wire.WireProbe" & k, initArguments = { "token" : expected } );
				var r        = probe.report();
				var bad      = [];
				if ( r.kind != k )                                  bad.append( "kind=" & r.kind );
				if ( r.token != expected )                          bad.append( "token=" & r.token );
				if ( r.settingsKind != k )                          bad.append( "settingsKind=" & r.settingsKind );
				if ( r.workerOwner != expected )                    bad.append( "workerOwner=" & r.workerOwner );
				if ( r.helperOwner != expected )                    bad.append( "helperOwner=" & r.helperOwner );
				if ( r.peerOwner != expected )                      bad.append( "peerOwner=" & r.peerOwner );
				if ( listLast( r.metaName, "." ) != "WireProbe" & k ) bad.append( "metaName=" & r.metaName );
				if ( bad.len() ) problems.append( "WireProbe#k# expected #expected#: " & bad.toList( ", " ) );
			}
		} catch ( any e ) {
			var classified = recordCorruption(
				"wire",
				e.message,
				e.keyExists( "detail" ) ? e.detail : "",
				e.keyExists( "type" ) ? e.type : "",
				e.keyExists( "stackTrace" ) ? e.stackTrace : ""
			);
			event.setHTTPHeader( statusCode = 500, statusText = "Repro Error" );
			return { "ok" : false, "corruption" : classified, "error" : e.message, "thread" : getThreadName() };
		}
		if ( problems.len() ) {
			var classified = recordCorruption( "wire", "WIRE_CROSSING " & problems.toList( " | " ) );
			event.setHTTPHeader( statusCode = 500, statusText = "Repro Error" );
			return { "ok" : false, "corruption" : classified, "problems" : problems, "thread" : getThreadName() };
		}
		return { "ok" : true, "probes" : 6, "thread" : getThreadName() };
	}

	/**
	 * GET /repro/tempvar
	 *
	 * The mechanism Adobe's fourth hotfix changes, one build per request so bombardier can drive
	 * it like the other endpoints. Asks the TempVarProbe SINGLETON to build an inline struct, an
	 * inline array and an invoke() argument struct around this request's token, with a short
	 * sleep inside each literal. Before v4 the literal's compiler temporary lives in the
	 * singleton's variables scope, shared by every request, so under concurrent load a request
	 * gets back another request's value. A mismatch is logged as TEMPVAR_CROSSING and returns
	 * HTTP 500. No database.
	 */
	function tempvar( event, rc, prc ) {
		var token = createUUID();
		var probe = getInstance( "models.torture.TempVarProbe" );
		var bad   = [];
		try {
			var s = probe.build( token, 2 );
			if ( s.token != token || s.again != token ) bad.append( "struct got " & s.token & " / " & s.again );
			var a = probe.buildArray( token, 2 );
			if ( a[ 1 ] != token || a[ 2 ] != token ) bad.append( "array got " & a[ 1 ] & " / " & a[ 2 ] );
			var v = probe.buildViaInvoke( token, 2 );
			if ( v != token ) bad.append( "invoke got " & v );
		} catch ( any e ) {
			var classified = recordCorruption(
				"tempvar",
				e.message,
				e.keyExists( "detail" ) ? e.detail : "",
				e.keyExists( "type" ) ? e.type : "",
				e.keyExists( "stackTrace" ) ? e.stackTrace : ""
			);
			event.setHTTPHeader( statusCode = 500, statusText = "Repro Error" );
			return { "ok" : false, "corruption" : classified, "error" : e.message, "thread" : getThreadName() };
		}
		if ( bad.len() ) {
			var classified = recordCorruption( "tempvar", "TEMPVAR_CROSSING expected " & token & ": " & bad.toList( " | " ) );
			event.setHTTPHeader( statusCode = 500, statusText = "Repro Error" );
			return { "ok" : false, "corruption" : classified, "problems" : bad, "thread" : getThreadName() };
		}
		return { "ok" : true, "builds" : 3, "thread" : getThreadName() };
	}

	// GET /repro/status — current contamination tally for this app instance
	function status( event, rc, prc ) {
		return {
			"contaminations" : application.keyExists( "contaminationCount" ) ? application.contaminationCount : 0,
			"thread"         : getThreadName()
		};
	}

	/**
	 * GET /repro/stress?entity=alpha&iterations=200
	 * Optional in-process stress mode: spawns bounded concurrent threads, each
	 * running the dissociate. External HTTP load (bombardier) is the canonical
	 * method; this is a convenience for quick local attempts.
	 */
	function stress( event, rc, prc ) {
		var entity     = ( rc.keyExists( "entity" ) && rc.entity == "bravo" ) ? "bravo" : "alpha";
		var iterations = min( val( rc.keyExists( "iterations" ) ? rc.iterations : 200 ), 500 );
		var errors     = [];
		var threadNames = [];

		for ( var i = 1; i <= iterations; i++ ) {
			var tName = "repro_#entity#_#i#";
			arrayAppend( threadNames, tName );
			thread name="#tName#" action="run" entityType="#entity#" {
				try {
					if ( attributes.entityType == "bravo" ) {
						var p = getInstance( "BravoParent" ).firstOrFail();
						p.setBravoChildren( getInstance( "BravoChild" ).all() );
					} else {
						var p = getInstance( "AlphaParent" ).firstOrFail();
						p.setAlphaChildren( getInstance( "AlphaChild" ).all() );
					}
				} catch ( any e ) {
					thread.errored = e.message;
					thread.erroredDetail = e.keyExists( "detail" ) ? e.detail : "";
					thread.erroredType = e.keyExists( "type" ) ? e.type : "";
					thread.erroredStack = e.keyExists( "stackTrace" ) ? e.stackTrace : "";
				}
			}
		}

		// join all spawned threads
		thread action="join" name="#arrayToList( threadNames )#";

		for ( var tName in threadNames ) {
			if ( structKeyExists( cfthread, tName ) && structKeyExists( cfthread[ tName ], "errored" ) ) {
				arrayAppend( errors, cfthread[ tName ].errored );
				recordCorruption(
					"stress(#entity#)",
					cfthread[ tName ].errored,
					structKeyExists( cfthread[ tName ], "erroredDetail" ) ? cfthread[ tName ].erroredDetail : "",
					structKeyExists( cfthread[ tName ], "erroredType" ) ? cfthread[ tName ].erroredType : "",
					structKeyExists( cfthread[ tName ], "erroredStack" ) ? cfthread[ tName ].erroredStack : ""
				);
			}
		}

		return {
			"entity"          : entity,
			"iterations"      : iterations,
			"threadErrors"    : errors.len(),
			"sampleErrors"    : errors.len() ? errors.slice( 1, min( 5, errors.len() ) ) : [],
			"contaminations"  : application.keyExists( "contaminationCount" ) ? application.contaminationCount : 0
		};
	}

	// ------------------------------------------------------------------ private

	private any function runRepro(
		required any event,
		required string entityName,
		required string childEntityName,
		required string relationship,
		required string expectedTable
	) {
		try {
			var parent   = getInstance( arguments.entityName ).firstOrFail();
			// Re-associate ALL child rows (not just currently-linked ones) so the data
			// self-heals across runs and the UPDATE always has rows. The setter routes
			// through applySetter -> updateAll -> UPDATE [expectedTable] SET [fk]=NULL.
			var children = getInstance( arguments.childEntityName ).all();
			invoke( parent, "set" & arguments.relationship, { "1" : children } );

			return {
				"ok"            : true,
				"entity"        : arguments.entityName,
				"expectedTable" : arguments.expectedTable,
				"childCount"    : children.len(),
				"thread"        : getThreadName()
			};
		} catch ( any e ) {
			// A contaminated UPDATE targets the wrong table, which lacks the FK
			// column -> SQL Server "Invalid column name ..." (mirrors production).
			// recordCorruption classifies known concurrency-corruption signatures for
			// the contamination log, but now logs EVERY failure (with type + stack) to
			// logs/repro_errors.txt so an unrecognised error (e.g. a dead servlet
			// deployment, a missing datasource) is never silently swallowed.
			var classified = recordCorruption(
				arguments.expectedTable,
				e.message,
				e.keyExists( "detail" ) ? e.detail : "",
				e.keyExists( "type" ) ? e.type : "",
				e.keyExists( "stackTrace" ) ? e.stackTrace : ""
			);
			arguments.event.setHTTPHeader( statusCode = 500, statusText = "Repro Error" );
			return {
				"ok"            : false,
				"entity"        : arguments.entityName,
				"expectedTable" : arguments.expectedTable,
				"corruption"    : classified,
				"errorType"     : e.keyExists( "type" ) ? e.type : "",
				"error"         : e.message,
				"detail"        : e.keyExists( "detail" ) ? e.detail : "",
				"thread"        : getThreadName()
			};
		}
	}

	/**
	 * Classifies an error and records it. EVERY failure is appended to
	 * logs/repro_errors.txt (with exception type + stack) so nothing is ever
	 * silently swallowed; recognised concurrency-corruption signatures are
	 * ALSO appended to logs/contamination_log.txt (the clean reproduction signal).
	 *
	 * Returns the corruption type ("TABLE_NAME_CONTAMINATION",
	 * "VARIABLES_SCOPE_CORRUPTION") or "" when the error is not a known corruption.
	 *
	 * @context     Where the error came from (entity/endpoint label).
	 * @errType     The exception type (cfcatch.type), when available.
	 * @stacktrace  The exception stack trace (cfcatch.stackTrace), when available.
	 */
	private string function recordCorruption(
		required string context,
		required string message,
		string detail = "",
		string errType = "",
		string stacktrace = ""
	) {
		var haystack = lCase( arguments.message & " " & arguments.detail & " " & arguments.errType );
		var type     = "";

		if ( haystack contains "wire_crossing" ) {
			// /repro/wire: a WireBox-built probe held a value that belongs to another request.
			type = "WIRE_CROSSING";
		} else if ( haystack contains "tempvar_crossing" ) {
			// /repro/tempvar: an inline literal built by a shared singleton came back holding
			// another request's value (the compiler temporary shared through variables).
			type = "TEMPVAR_CROSSING";
		} else if ( haystack contains "invalid column name" || haystack contains "invalid object name" ) {
			// UPDATE hit the wrong table (it lacks the other entity's FK column).
			type = "TABLE_NAME_CONTAMINATION";
		} else if ( haystack contains "is undefined in a java object" || haystack contains "_str" ) {
			// A BaseEntity's variables-scoped property resolved to another
			// instance's value during concurrent transient construction.
			type = "VARIABLES_SCOPE_CORRUPTION";
		} else if ( haystack contains "method does not exist on querybuilder" || haystack contains "couldn't figure out what to do with" ) {
			// The entity's cached metadata (variables._meta) resolved to another
			// instance, so hasRelationship() could not see the entity's own
			// relationship -> onMissingMethod forwarded the setter to qb, which has
			// no such method. Same variables-scope defect, different victim property.
			type = "VARIABLES_SCOPE_CORRUPTION";
		}

		var logDir = expandPath( "/logs" );
		if ( !directoryExists( logDir ) ) {
			directoryCreate( logDir );
		}

		var evt = {
			"detectedAt" : dateTimeFormat( now(), "yyyy-mm-dd HH:nn:ss.lll" ),
			"type"       : len( type ) ? type : "UNCLASSIFIED",
			"context"    : arguments.context,
			"thread"     : getThreadName(),
			"errType"    : arguments.errType,
			"message"    : arguments.message,
			"detail"     : arguments.detail,
			"stacktrace" : left( arguments.stacktrace, 2000 )
		};

		// Forensic capture of EVERY failure (classified or not).
		fileAppend( logDir & "/repro_errors.txt", evt.type & " " & serializeJSON( evt ) & chr( 10 ), "UTF-8" );

		if ( !len( type ) ) {
			return "";
		}

		// Recognised corruption only -> the clean reproduction signal. Keep this
		// entry slim (no stack) to preserve the documented contamination_log format.
		var corruptionEvt = {
			"detectedAt" : evt.detectedAt,
			"type"       : type,
			"context"    : arguments.context,
			"thread"     : evt.thread,
			"message"    : arguments.message,
			"detail"     : arguments.detail
		};
		fileAppend( logDir & "/contamination_log.txt", type & " " & serializeJSON( corruptionEvt ) & chr( 10 ), "UTF-8" );
		return type;
	}

	private string function getThreadName() {
		return createObject( "java", "java.lang.Thread" ).currentThread().getName();
	}

}
