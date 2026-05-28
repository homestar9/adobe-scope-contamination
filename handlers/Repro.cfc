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
					structKeyExists( cfthread[ tName ], "erroredDetail" ) ? cfthread[ tName ].erroredDetail : ""
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
			// recordCorruption only logs recognised concurrency-corruption
			// signatures; benign failures (e.g. a missing datasource) are returned
			// but not logged as corruption.
			var classified = recordCorruption(
				arguments.expectedTable,
				e.message,
				e.keyExists( "detail" ) ? e.detail : ""
			);
			arguments.event.setHTTPHeader( statusCode = 500, statusText = "Repro Error" );
			return {
				"ok"            : false,
				"entity"        : arguments.entityName,
				"expectedTable" : arguments.expectedTable,
				"corruption"    : classified,
				"error"         : e.message,
				"detail"        : e.keyExists( "detail" ) ? e.detail : "",
				"thread"        : getThreadName()
			};
		}
	}

	/**
	 * Classifies an error message/detail and, if it matches a known concurrency
	 * corruption signature, appends a structured event to logs/contamination_log.txt.
	 *
	 * Returns the corruption type ("TABLE_NAME_CONTAMINATION",
	 * "VARIABLES_SCOPE_CORRUPTION") or "" when the error is not corruption.
	 *
	 * @context  Where the error came from (entity/endpoint label).
	 */
	private string function recordCorruption( required string context, required string message, string detail = "" ) {
		var haystack = lCase( arguments.message & " " & arguments.detail );
		var type     = "";

		if ( haystack contains "invalid column name" || haystack contains "invalid object name" ) {
			// UPDATE hit the wrong table (it lacks the other entity's FK column).
			type = "TABLE_NAME_CONTAMINATION";
		} else if ( haystack contains "is undefined in a java object" || haystack contains "_str" ) {
			// A BaseEntity's variables-scoped property resolved to another
			// instance's value during concurrent transient construction.
			type = "VARIABLES_SCOPE_CORRUPTION";
		}

		if ( !len( type ) ) {
			return "";
		}

		var logDir = expandPath( "/logs" );
		if ( !directoryExists( logDir ) ) {
			directoryCreate( logDir );
		}
		var evt = {
			"detectedAt" : dateTimeFormat( now(), "yyyy-mm-dd HH:nn:ss.lll" ),
			"type"       : type,
			"context"    : arguments.context,
			"thread"     : getThreadName(),
			"message"    : arguments.message,
			"detail"     : arguments.detail
		};
		fileAppend( logDir & "/contamination_log.txt", type & " " & serializeJSON( evt ) & chr( 10 ), "UTF-8" );
		return type;
	}

	private string function getThreadName() {
		return createObject( "java", "java.lang.Thread" ).currentThread().getName();
	}

}
