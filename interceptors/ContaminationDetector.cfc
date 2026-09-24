/**
 * ContaminationDetector
 *
 * Listens on qb's `preQBExecute` interception point (fired by
 * qb/models/Grammars/BaseGrammar.cfc just before queryExecute()) and inspects
 * every generated SQL statement for cross-entity table-name contamination.
 *
 * Detection rule (works because the two child tables use differently-prefixed
 * FK columns): for any UPDATE against alpha_child / bravo_child, the prefix of
 * the target table MUST match the prefix of the column being SET.
 *
 *   correct      : UPDATE [alpha_child] SET [alpha_parent_id] = NULL ...   (alpha == alpha)
 *   contaminated : UPDATE [bravo_child] SET [alpha_parent_id] = NULL ...   (bravo != alpha)
 *
 * On a mismatch we record the event (thread name, full SQL, bindings, time) to
 * logs/contamination_log.txt and bump an application-scoped counter. This fires
 * BEFORE SQL Server would itself error on the missing column, giving a clean,
 * unambiguous signal even on grammars/configs that might not throw.
 */
component {

	property name="log" inject="logbox:logger:{this}";

	void function configure() {
	}

	/**
	 * @event        ColdBox RequestContext
	 * @interceptData The qb execution payload: { sql, bindings, options, ... }
	 */
	void function preQBExecute( required any event, required struct interceptData ) {
		var sql = arguments.interceptData.keyExists( "sql" ) ? arguments.interceptData.sql : "";
		if ( !len( sql ) || !reFindNoCase( "^\s*UPDATE\b", sql ) ) {
			return;
		}

		var targetTable = extractFirstGroup( "UPDATE\s+\[?([a-zA-Z0-9_]+)\]?", sql );
		var setColumn   = extractFirstGroup( "SET\s+\[?([a-zA-Z0-9_]+)\]?", sql );

		// Only evaluate UPDATEs that touch our reproduction child tables.
		if ( !reFindNoCase( "^(alpha|bravo)_child$", targetTable ) ) {
			return;
		}

		var tablePrefix  = listFirst( lCase( targetTable ), "_" );
		var columnPrefix = listFirst( lCase( setColumn ), "_" );

		if ( tablePrefix == columnPrefix ) {
			return; // healthy: table and column agree
		}

		recordContamination( {
			"detectedAt"   : dateTimeFormat( now(), "yyyy-mm-dd HH:nn:ss.lll" ),
			"thread"       : getThreadName(),
			"targetTable"  : targetTable,
			"setColumn"    : setColumn,
			"expectedTable": columnPrefix & "_child",
			"sql"          : trim( sql ),
			"bindings"     : arguments.interceptData.keyExists( "bindings" ) ? serializeBindings( arguments.interceptData.bindings ) : ""
		} );
	}

	/**
	 * Fired by the patched Quick module (patches/quick/0002) when the
	 * entity-table guard finds a builder whose table does not match its entity
	 * just before execution.  Records each event so gate runs can count how
	 * many statements the guard caught (and, in repair mode, fixed) before
	 * any SQL ran.  With stock Quick this interception point does not exist,
	 * so this method is simply never called.
	 */
	void function quickEntityTableMismatch( required any event, required struct interceptData ) {
		application.tableRepairCount = ( application.keyExists( "tableRepairCount" ) ? application.tableRepairCount : 0 ) + 1;

		var logDir = expandPath( "/logs" );
		if ( !directoryExists( logDir ) ) {
			directoryCreate( logDir );
		}
		var line = "TABLE_MISMATCH_CAUGHT ##" & application.tableRepairCount & " " & serializeJSON( {
			"detectedAt"    : dateTimeFormat( now(), "yyyy-mm-dd HH:nn:ss.lll" ),
			"thread"        : getThreadName(),
			"operation"     : arguments.interceptData.keyExists( "operation" ) ? arguments.interceptData.operation : "",
			"expectedTable" : arguments.interceptData.keyExists( "expectedTable" ) ? arguments.interceptData.expectedTable : "",
			"actualTable"   : arguments.interceptData.keyExists( "actualTable" ) ? arguments.interceptData.actualTable : "",
			"repaired"      : arguments.interceptData.keyExists( "repaired" ) ? arguments.interceptData.repaired : ""
		} ) & chr( 10 );
		fileAppend( logDir & "/contamination_log.txt", line, "UTF-8" );

		variables.log.warn( "QUICK TABLE MISMATCH CAUGHT: " & line );
	}

	// ------------------------------------------------------------------ helpers

	private string function extractFirstGroup( required string pattern, required string subject ) {
		var m = reFindNoCase( arguments.pattern, arguments.subject, 1, true );
		if ( arrayLen( m.pos ) >= 2 && m.pos[ 2 ] > 0 ) {
			return mid( arguments.subject, m.pos[ 2 ], m.len[ 2 ] );
		}
		return "";
	}

	private string function getThreadName() {
		return createObject( "java", "java.lang.Thread" ).currentThread().getName();
	}

	private string function serializeBindings( required any bindings ) {
		try {
			return serializeJSON( arguments.bindings );
		} catch ( any e ) {
			return "[unserializable bindings]";
		}
	}

	private void function recordContamination( required struct evt ) {
		application.contaminationCount = ( application.keyExists( "contaminationCount" ) ? application.contaminationCount : 0 ) + 1;

		var logDir = expandPath( "/logs" );
		if ( !directoryExists( logDir ) ) {
			directoryCreate( logDir );
		}
		var line = "CONTAMINATION ##" & application.contaminationCount & " " & serializeJSON( arguments.evt ) & chr( 10 );
		fileAppend( logDir & "/contamination_log.txt", line, "UTF-8" );

		variables.log.error( "SCOPE CONTAMINATION DETECTED: " & serializeJSON( arguments.evt ) );
	}

}
