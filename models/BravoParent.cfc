/**
 * BravoParent — has many BravoChild via bravo_child.bravo_parent_id.
 *
 * Transient: resolved fresh per request via WireBox getInstance().
 */
component
	extends   ="quick.models.BaseEntity"
	accessors ="true"
	table     ="bravo_parent"
{

	property name="id";
	property name="name";

	function bravoChildren() {
		return hasMany( "BravoChild", "bravo_parent_id" );
	}

}
