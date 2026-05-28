/**
 * AlphaParent — has many AlphaChild via alpha_child.alpha_parent_id.
 *
 * Transient: resolved fresh per request via WireBox getInstance().
 */
component
	extends   ="quick.models.BaseEntity"
	accessors ="true"
	table     ="alpha_parent"
{

	property name="id";
	property name="name";

	function alphaChildren() {
		return hasMany( "AlphaChild", "alpha_parent_id" );
	}

}
