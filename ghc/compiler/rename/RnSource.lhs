%
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1998
%
\section[RnSource]{Main pass of renamer}

\begin{code}
module RnSource ( rnDecl, rnSourceDecls, rnHsType, rnHsSigType ) where

#include "HsVersions.h"

import RnExpr
import HsSyn
import HsPragmas
import HsTypes		( getTyVarName, pprClassAssertion, cmpHsTypes )
import RdrName		( RdrName, isRdrDataCon, rdrNameOcc, isRdrTyVar )
import RdrHsSyn		( RdrNameContext, RdrNameHsType, RdrNameConDecl,
			  extractRuleBndrsTyVars, extractHsTyRdrTyVars
			)
import RnHsSyn
import HsCore

import RnBinds		( rnTopBinds, rnMethodBinds, renameSigs, unknownSigErr )
import RnEnv		( bindTyVarsRn, lookupBndrRn, lookupOccRn, 
			  lookupImplicitOccRn, 
			  bindLocalsRn, bindLocalRn, bindLocalsFVRn,
			  bindTyVarsFVRn, bindTyVarsFV2Rn, extendTyVarEnvFVRn,
			  bindCoreLocalFVRn, bindCoreLocalsFVRn,
			  checkDupOrQualNames, checkDupNames,
			  mkImportedGlobalName, mkImportedGlobalFromRdrName,
			  newDFunName, getDFunKey, newImplicitBinder,
			  FreeVars, emptyFVs, plusFV, plusFVs, unitFV, addOneFV, mapFvRn
			)
import RnMonad

import Name		( Name, OccName,
			  ExportFlag(..), Provenance(..), 
			  nameOccName, NamedThing(..)
			)
import NameSet
import OccName		( mkDefaultMethodOcc )
import BasicTypes	( TopLevelFlag(..) )
import FiniteMap	( elemFM )
import PrelInfo		( derivableClassKeys,
			  deRefStablePtr_NAME, makeStablePtr_NAME, bindIO_NAME
			)
import Bag		( bagToList )
import List		( partition, nub )
import Outputable
import SrcLoc		( SrcLoc )
import CmdLineOpts	( opt_WarnUnusedMatches )	-- Warn of unused for-all'd tyvars
import Unique		( Uniquable(..) )
import UniqFM		( lookupUFM )
import Maybes		( maybeToBool, catMaybes )
import Util
\end{code}

@rnDecl@ `renames' declarations.
It simultaneously performs dependency analysis and precedence parsing.
It also does the following error checks:
\begin{enumerate}
\item
Checks that tyvars are used properly. This includes checking
for undefined tyvars, and tyvars in contexts that are ambiguous.
\item
Checks that all variable occurences are defined.
\item 
Checks the @(..)@ etc constraints in the export list.
\end{enumerate}


%*********************************************************
%*							*
\subsection{Value declarations}
%*							*
%*********************************************************

\begin{code}
rnSourceDecls :: [RdrNameHsDecl] -> RnMS ([RenamedHsDecl], FreeVars)
	-- The decls get reversed, but that's ok

rnSourceDecls decls
  = go emptyFVs [] decls
  where
	-- Fixity decls have been dealt with already; ignore them
    go fvs ds' []          = returnRn (ds', fvs)
    go fvs ds' (FixD _:ds) = go fvs ds' ds
    go fvs ds' (d:ds)      = rnDecl d	`thenRn` \(d', fvs') ->
			     go (fvs `plusFV` fvs') (d':ds') ds
\end{code}


%*********************************************************
%*							*
\subsection{Value declarations}
%*							*
%*********************************************************

\begin{code}
-- rnDecl does all the work
rnDecl :: RdrNameHsDecl -> RnMS (RenamedHsDecl, FreeVars)

rnDecl (ValD binds) = rnTopBinds binds	`thenRn` \ (new_binds, fvs) ->
		      returnRn (ValD new_binds, fvs)


rnDecl (SigD (IfaceSig name ty id_infos loc))
  = pushSrcLocRn loc $
    lookupBndrRn name		`thenRn` \ name' ->
    rnHsType doc_str ty		`thenRn` \ (ty',fvs1) ->
    mapFvRn rnIdInfo id_infos	`thenRn` \ (id_infos', fvs2) -> 
    returnRn (SigD (IfaceSig name' ty' id_infos' loc), fvs1 `plusFV` fvs2)
  where
    doc_str = text "the interface signature for" <+> quotes (ppr name)
\end{code}

%*********************************************************
%*							*
\subsection{Type declarations}
%*							*
%*********************************************************

@rnTyDecl@ uses the `global name function' to create a new type
declaration in which local names have been replaced by their original
names, reporting any unknown names.

Renaming type variables is a pain. Because they now contain uniques,
it is necessary to pass in an association list which maps a parsed
tyvar to its @Name@ representation.
In some cases (type signatures of values),
it is even necessary to go over the type first
in order to get the set of tyvars used by it, make an assoc list,
and then go over it again to rename the tyvars!
However, we can also do some scoping checks at the same time.

\begin{code}
rnDecl (TyClD (TyData new_or_data context tycon tyvars condecls derivings pragmas src_loc))
  = pushSrcLocRn src_loc $
    lookupBndrRn tycon			    	`thenRn` \ tycon' ->
    bindTyVarsFVRn data_doc tyvars		$ \ tyvars' ->
    rnContext data_doc context 			`thenRn` \ (context', cxt_fvs) ->
    checkDupOrQualNames data_doc con_names	`thenRn_`
    mapFvRn rnConDecl condecls			`thenRn` \ (condecls', con_fvs) ->
    rnDerivs derivings				`thenRn` \ (derivings', deriv_fvs) ->
    ASSERT(isNoDataPragmas pragmas)
    returnRn (TyClD (TyData new_or_data context' tycon' tyvars' condecls'
                     derivings' noDataPragmas src_loc),
	      cxt_fvs `plusFV` con_fvs `plusFV` deriv_fvs)
  where
    data_doc = text "the data type declaration for" <+> quotes (ppr tycon)
    con_names = map conDeclName condecls

rnDecl (TyClD (TySynonym name tyvars ty src_loc))
  = pushSrcLocRn src_loc $
    lookupBndrRn name				`thenRn` \ name' ->
    bindTyVarsFVRn syn_doc tyvars 		$ \ tyvars' ->
    rnHsType syn_doc ty				`thenRn` \ (ty', ty_fvs) ->
    returnRn (TyClD (TySynonym name' tyvars' ty' src_loc), ty_fvs)
  where
    syn_doc = text "the declaration for type synonym" <+> quotes (ppr name)

rnDecl (TyClD (ClassDecl context cname tyvars sigs mbinds pragmas
               tname dname snames src_loc))
  = pushSrcLocRn src_loc $

    lookupBndrRn cname					`thenRn` \ cname' ->

	-- Deal with the implicit tycon and datacon name
	-- They aren't in scope (because they aren't visible to the user)
	-- and what we want to do is simply look them up in the cache;
	-- we jolly well ought to get a 'hit' there!
	-- So the 'Imported' part of this call is not relevant. 
	-- Unclean; but since these two are the only place this happens
	-- I can't work up the energy to do it more beautifully
    mkImportedGlobalFromRdrName tname			`thenRn` \ tname' ->
    mkImportedGlobalFromRdrName dname			`thenRn` \ dname' ->
    mapRn mkImportedGlobalFromRdrName snames		`thenRn` \ snames' ->

	-- Tyvars scope over bindings and context
    bindTyVarsFV2Rn cls_doc tyvars		( \ clas_tyvar_names tyvars' ->

	-- Check the superclasses
    rnContext cls_doc context			`thenRn` \ (context', cxt_fvs) ->

	-- Check the signatures
    let
	    -- First process the class op sigs, then the fixity sigs.
	  (op_sigs, non_op_sigs) = partition isClassOpSig sigs
	  (fix_sigs, non_sigs)   = partition isFixitySig  non_op_sigs
    in
    checkDupOrQualNames sig_doc sig_rdr_names_w_locs 	`thenRn_` 
    mapFvRn (rn_op cname' clas_tyvar_names) op_sigs
    `thenRn` \ (sigs', sig_fvs) ->
    mapRn_  (unknownSigErr) non_sigs			`thenRn_`
    let
     binders = mkNameSet [ nm | (ClassOpSig nm _ _ _) <- sigs' ]
    in
    renameSigs False binders lookupOccRn fix_sigs
    `thenRn` \ (fixs', fix_fvs) ->

	-- Check the methods
    checkDupOrQualNames meth_doc meth_rdr_names_w_locs	`thenRn_`
    rnMethodBinds mbinds
    `thenRn` \ (mbinds', meth_fvs) ->

	-- Typechecker is responsible for checking that we only
	-- give default-method bindings for things in this class.
	-- The renamer *could* check this for class decls, but can't
	-- for instance decls.

    ASSERT(isNoClassPragmas pragmas)
    returnRn (TyClD (ClassDecl context' cname' tyvars' (fixs' ++ sigs') mbinds'
			       NoClassPragmas tname' dname' snames' src_loc),
	      sig_fvs	`plusFV`
	      fix_fvs	`plusFV`
	      cxt_fvs	`plusFV`
	      meth_fvs
	     )
    )
  where
    cls_doc  = text "the declaration for class" 	<+> ppr cname
    sig_doc  = text "the signatures for class"  	<+> ppr cname
    meth_doc = text "the default-methods for class"	<+> ppr cname

    sig_rdr_names_w_locs  = [(op,locn) | ClassOpSig op _ _ locn <- sigs]
    meth_rdr_names_w_locs = bagToList (collectMonoBinders mbinds)
    meth_rdr_names	  = map fst meth_rdr_names_w_locs

    rn_op clas clas_tyvars sig@(ClassOpSig op maybe_dm ty locn)
      = pushSrcLocRn locn $
 	lookupBndrRn op				`thenRn` \ op_name ->

		-- Check the signature
	rnHsSigType (quotes (ppr op)) ty	`thenRn` \ (new_ty, op_ty_fvs)  ->
	let
	    check_in_op_ty clas_tyvar =
		 checkRn (clas_tyvar `elemNameSet` op_ty_fvs)
			 (classTyVarNotInOpTyErr clas_tyvar sig)
	in
        mapRn_ check_in_op_ty clas_tyvars		 `thenRn_`

		-- Make the default-method name
	getModeRn					`thenRn` \ mode ->
	(case (mode, maybe_dm) of 
	    (SourceMode, _)
		| op `elem` meth_rdr_names
		-> -- Source class decl with an explicit method decl
		   newImplicitBinder (mkDefaultMethodOcc (rdrNameOcc op)) locn
   	 	   `thenRn` \ dm_name ->
		   returnRn (Just dm_name, emptyFVs)

		| otherwise	
		->	-- Source class dec, no explicit method decl
			returnRn (Nothing, emptyFVs)

	    (InterfaceMode, Just dm_rdr_name)
		-> 	-- Imported class that has a default method decl
			-- See comments with tname, snames, above
		    lookupImplicitOccRn dm_rdr_name 	`thenRn` \ dm_name ->
		    returnRn (Just dm_name, unitFV dm_name)
			    -- An imported class decl mentions, rather than defines,
			    -- the default method, so we must arrange to pull it in

	    (InterfaceMode, Nothing)
	    		-- Imported class with no default metho
		-> 	returnRn (Nothing, emptyFVs)
	)						`thenRn` \ (maybe_dm_name, dm_fvs) ->

	returnRn (ClassOpSig op_name maybe_dm_name new_ty locn, op_ty_fvs `plusFV` dm_fvs)
\end{code}


%*********************************************************
%*							*
\subsection{Instance declarations}
%*							*
%*********************************************************

\begin{code}
rnDecl (InstD (InstDecl inst_ty mbinds uprags dfun_rdr_name src_loc))
  = pushSrcLocRn src_loc $
    rnHsSigType (text "an instance decl") inst_ty `thenRn` \ (inst_ty', inst_fvs) ->
    let
	inst_tyvars = case inst_ty' of
			HsForAllTy (Just inst_tyvars) _ _ -> inst_tyvars
			other			          -> []
	-- (Slightly strangely) the forall-d tyvars scope over
	-- the method bindings too
    in

	-- Rename the bindings
	-- NB meth_names can be qualified!
    checkDupNames meth_doc meth_names 		`thenRn_`
    extendTyVarEnvFVRn inst_tyvars (		
	rnMethodBinds mbinds
    )						`thenRn` \ (mbinds', meth_fvs) ->
    let 
	binders = mkNameSet (map fst (bagToList (collectMonoBinders mbinds')))

	-- Delete sigs (&report) sigs that aren't allowed inside an
	-- instance decl:
	--
	--  + type signatures
	--  + fixity decls
	--
	(ok_sigs, not_ok_idecl_sigs) = partition okInInstDecl uprags
	
	okInInstDecl (FixSig _)  = False
	okInInstDecl (Sig _ _ _) = False
	okInInstDecl _		 = True
	
    in
      -- You can't have fixity decls & type signatures
      -- within an instance declaration.
    mapRn_ unknownSigErr not_ok_idecl_sigs       `thenRn_`

	-- Rename the prags and signatures.
	-- Note that the type variables are not in scope here,
	-- so that	instance Eq a => Eq (T a) where
	--			{-# SPECIALISE instance Eq a => Eq (T [a]) #-}
	-- works OK. 
    renameSigs False binders lookupOccRn ok_sigs `thenRn` \ (new_uprags, prag_fvs) ->

    getModeRn		`thenRn` \ mode ->
    (case mode of
	InterfaceMode -> lookupImplicitOccRn dfun_rdr_name	`thenRn` \ dfun_name ->
			 returnRn (dfun_name, unitFV dfun_name)
	SourceMode    -> newDFunName (getDFunKey inst_ty') src_loc
                         `thenRn` \ dfun_name ->
			 returnRn (dfun_name, emptyFVs)
    )
    `thenRn` \ (dfun_name, dfun_fv) ->

    -- The typechecker checks that all the bindings are for the right class.
    returnRn (InstD (InstDecl inst_ty' mbinds' new_uprags dfun_name src_loc),
	      inst_fvs `plusFV` meth_fvs `plusFV` prag_fvs `plusFV` dfun_fv)
  where
    meth_doc = text "the bindings in an instance declaration"
    meth_names   = bagToList (collectMonoBinders mbinds)
\end{code}

%*********************************************************
%*							*
\subsection{Default declarations}
%*							*
%*********************************************************

\begin{code}
rnDecl (DefD (DefaultDecl tys src_loc))
  = pushSrcLocRn src_loc $
    rnHsTypes doc_str tys		`thenRn` \ (tys', fvs) ->
    returnRn (DefD (DefaultDecl tys' src_loc), fvs)
  where
    doc_str = text "a `default' declaration"
\end{code}

%*********************************************************
%*							*
\subsection{Foreign declarations}
%*							*
%*********************************************************

\begin{code}
rnDecl (ForD (ForeignDecl name imp_exp ty ext_nm cconv src_loc))
  = pushSrcLocRn src_loc $
    lookupOccRn name		        `thenRn` \ name' ->
    let 
	fvs1 = case imp_exp of
		FoImport _ | not isDyn	-> emptyFVs
		FoLabel    		-> emptyFVs
		FoExport   | isDyn	-> mkNameSet [makeStablePtr_NAME,
						      deRefStablePtr_NAME,
						      bindIO_NAME]
			   | otherwise  -> mkNameSet [name']
		_ -> emptyFVs
    in
    rnHsSigType fo_decl_msg ty		        `thenRn` \ (ty', fvs2) ->
    returnRn (ForD (ForeignDecl name' imp_exp ty' ext_nm cconv src_loc), 
	      fvs1 `plusFV` fvs2)
 where
  fo_decl_msg = ptext SLIT("a foreign declaration")
  isDyn	      = isDynamic ext_nm
\end{code}

%*********************************************************
%*							*
\subsection{Rules}
%*							*
%*********************************************************

\begin{code}
rnDecl (RuleD (IfaceRuleDecl var body src_loc))
  = pushSrcLocRn src_loc			$
    lookupOccRn var		`thenRn` \ var' ->
    rnRuleBody body		`thenRn` \ (body', fvs) ->
    returnRn (RuleD (IfaceRuleDecl var' body' src_loc), fvs `addOneFV` var')

rnDecl (RuleD (RuleDecl rule_name tvs vars lhs rhs src_loc))
  = ASSERT( null tvs )
    pushSrcLocRn src_loc			$

    bindTyVarsFV2Rn doc (map UserTyVar sig_tvs)	$ \ sig_tvs' _ ->
    bindLocalsFVRn doc (map get_var vars)	$ \ ids ->
    mapFvRn rn_var (vars `zip` ids)		`thenRn` \ (vars', fv_vars) ->

    rnExpr lhs					`thenRn` \ (lhs', fv_lhs) ->
    rnExpr rhs					`thenRn` \ (rhs', fv_rhs) ->
    checkRn (validRuleLhs ids lhs')
	    (badRuleLhsErr rule_name lhs')	`thenRn_`
    let
	bad_vars = [var | var <- ids, not (var `elemNameSet` fv_lhs)]
    in
    mapRn (addErrRn . badRuleVar rule_name) bad_vars	`thenRn_`
    returnRn (RuleD (RuleDecl rule_name sig_tvs' vars' lhs' rhs' src_loc),
	      fv_vars `plusFV` fv_lhs `plusFV` fv_rhs)
  where
    doc = text "the transformation rule" <+> ptext rule_name
    sig_tvs = extractRuleBndrsTyVars vars
  
    get_var (RuleBndr v)      = v
    get_var (RuleBndrSig v _) = v

    rn_var (RuleBndr v, id)	 = returnRn (RuleBndr id, emptyFVs)
    rn_var (RuleBndrSig v t, id) = rnHsType doc t	`thenRn` \ (t', fvs) ->
				   returnRn (RuleBndrSig id t', fvs)
\end{code}


%*********************************************************
%*							*
\subsection{Support code for type/data declarations}
%*							*
%*********************************************************

\begin{code}
rnDerivs :: Maybe [RdrName] -> RnMS (Maybe [Name], FreeVars)

rnDerivs Nothing -- derivs not specified
  = returnRn (Nothing, emptyFVs)

rnDerivs (Just clss)
  = mapRn do_one clss	`thenRn` \ clss' ->
    returnRn (Just clss', mkNameSet clss')
  where
    do_one cls = lookupOccRn cls	`thenRn` \ clas_name ->
		 checkRn (getUnique clas_name `elem` derivableClassKeys)
			 (derivingNonStdClassErr clas_name)	`thenRn_`
		 returnRn clas_name
\end{code}

\begin{code}
conDeclName :: RdrNameConDecl -> (RdrName, SrcLoc)
conDeclName (ConDecl n _ _ _ l) = (n,l)

rnConDecl :: RdrNameConDecl -> RnMS (RenamedConDecl, FreeVars)
rnConDecl (ConDecl name tvs cxt details locn)
  = pushSrcLocRn locn $
    checkConName name			`thenRn_` 
    lookupBndrRn name			`thenRn` \ new_name ->
    bindTyVarsFVRn doc tvs 		$ \ new_tyvars ->
    rnContext doc cxt			`thenRn` \ (new_context, cxt_fvs) ->
    rnConDetails doc locn details	`thenRn` \ (new_details, det_fvs) -> 
    returnRn (ConDecl new_name new_tyvars new_context new_details locn,
	      cxt_fvs `plusFV` det_fvs)
  where
    doc = text "the definition of data constructor" <+> quotes (ppr name)

rnConDetails doc locn (VanillaCon tys)
  = mapFvRn (rnBangTy doc) tys	`thenRn` \ (new_tys, fvs)  ->
    returnRn (VanillaCon new_tys, fvs)

rnConDetails doc locn (InfixCon ty1 ty2)
  = rnBangTy doc ty1  		`thenRn` \ (new_ty1, fvs1) ->
    rnBangTy doc ty2  		`thenRn` \ (new_ty2, fvs2) ->
    returnRn (InfixCon new_ty1 new_ty2, fvs1 `plusFV` fvs2)

rnConDetails doc locn (NewCon ty mb_field)
  = rnHsType doc ty			`thenRn` \ (new_ty, fvs) ->
    rn_field mb_field			`thenRn` \ new_mb_field  ->
    returnRn (NewCon new_ty new_mb_field, fvs)
  where
    rn_field Nothing  = returnRn Nothing
    rn_field (Just f) =
       lookupBndrRn f	    `thenRn` \ new_f ->
       returnRn (Just new_f)

rnConDetails doc locn (RecCon fields)
  = checkDupOrQualNames doc field_names	`thenRn_`
    mapFvRn (rnField doc) fields	`thenRn` \ (new_fields, fvs) ->
    returnRn (RecCon new_fields, fvs)
  where
    field_names = [(fld, locn) | (flds, _) <- fields, fld <- flds]

rnField doc (names, ty)
  = mapRn lookupBndrRn names	`thenRn` \ new_names ->
    rnBangTy doc ty		`thenRn` \ (new_ty, fvs) ->
    returnRn ((new_names, new_ty), fvs) 

rnBangTy doc (Banged ty)
  = rnHsType doc ty		`thenRn` \ (new_ty, fvs) ->
    returnRn (Banged new_ty, fvs)

rnBangTy doc (Unbanged ty)
  = rnHsType doc ty 		`thenRn` \ (new_ty, fvs) ->
    returnRn (Unbanged new_ty, fvs)

rnBangTy doc (Unpacked ty)
  = rnHsType doc ty 		`thenRn` \ (new_ty, fvs) ->
    returnRn (Unpacked new_ty, fvs)

-- This data decl will parse OK
--	data T = a Int
-- treating "a" as the constructor.
-- It is really hard to make the parser spot this malformation.
-- So the renamer has to check that the constructor is legal
--
-- We can get an operator as the constructor, even in the prefix form:
--	data T = :% Int Int
-- from interface files, which always print in prefix form

checkConName name
  = checkRn (isRdrDataCon name)
	    (badDataCon name)
\end{code}


%*********************************************************
%*							*
\subsection{Support code to rename types}
%*							*
%*********************************************************

\begin{code}
rnHsSigType :: SDoc -> RdrNameHsType -> RnMS (RenamedHsType, FreeVars)
	-- rnHsSigType is used for source-language type signatures,
	-- which use *implicit* universal quantification.
rnHsSigType doc_str ty
  = rnHsType (text "the type signature for" <+> doc_str) ty
    
rnForAll doc forall_tyvars ctxt ty
  = bindTyVarsFVRn doc forall_tyvars	$ \ new_tyvars ->
    rnContext doc ctxt			`thenRn` \ (new_ctxt, cxt_fvs) ->
    rnHsType doc ty			`thenRn` \ (new_ty, ty_fvs) ->
    returnRn (mkHsForAllTy new_tyvars new_ctxt new_ty,
	      cxt_fvs `plusFV` ty_fvs)

-- Check that each constraint mentions at least one of the forall'd type variables
-- Since the forall'd type variables are a subset of the free tyvars
-- of the tau-type part, this guarantees that every constraint mentions
-- at least one of the free tyvars in ty
checkConstraints explicit_forall doc forall_tyvars ctxt ty
   = mapRn check ctxt			`thenRn` \ maybe_ctxt' ->
     returnRn (catMaybes maybe_ctxt')
	    -- Remove problem ones, to avoid duplicate error message.
   where
     check ct@(_,tys)
	| forall_mentioned = returnRn (Just ct)
	| otherwise	   = addErrRn (ctxtErr explicit_forall doc forall_tyvars ct ty)
			     `thenRn_` returnRn Nothing
        where
	  forall_mentioned = foldr ((||) . any (`elem` forall_tyvars) . extractHsTyRdrTyVars)
			     False
			     tys

rnHsType :: SDoc -> RdrNameHsType -> RnMS (RenamedHsType, FreeVars)

rnHsType doc (HsForAllTy Nothing ctxt ty)
	-- From source code (no kinds on tyvars)
	-- Given the signature  C => T  we universally quantify 
	-- over FV(T) \ {in-scope-tyvars} 
  = getLocalNameEnv		`thenRn` \ name_env ->
    let
	mentioned_in_tau = extractHsTyRdrTyVars ty
	forall_tyvars    = filter (not . (`elemFM` name_env)) mentioned_in_tau
    in
    checkConstraints False doc forall_tyvars ctxt ty	`thenRn` \ ctxt' ->
    rnForAll doc (map UserTyVar forall_tyvars) ctxt' ty

rnHsType doc (HsForAllTy (Just forall_tyvars) ctxt tau)
	-- Explicit quantification.
	-- Check that the forall'd tyvars are a subset of the
	-- free tyvars in the tau-type part
	-- That's only a warning... unless the tyvar is constrained by a 
	-- context in which case it's an error
  = let
	mentioned_in_tau  = extractHsTyRdrTyVars tau
	mentioned_in_ctxt = nub [tv | (_,tys) <- ctxt,
				      ty <- tys,
				      tv <- extractHsTyRdrTyVars ty]

	dubious_guys	      = filter (`notElem` mentioned_in_tau) forall_tyvar_names
		-- dubious = explicitly quantified but not mentioned in tau type

	(bad_guys, warn_guys) = partition (`elem` mentioned_in_ctxt) dubious_guys
		-- bad  = explicitly quantified and constrained, but not mentioned in tau
		-- warn = explicitly quantified but not mentioned in ctxt or tau
 
	forall_tyvar_names    = map getTyVarName forall_tyvars
    in
    mapRn_ (forAllErr doc tau) bad_guys 			`thenRn_`
    mapRn_ (forAllWarn doc tau) warn_guys			`thenRn_`
    checkConstraints True doc forall_tyvar_names ctxt tau	`thenRn` \ ctxt' ->
    rnForAll doc forall_tyvars ctxt' tau

rnHsType doc (MonoTyVar tyvar)
  = lookupOccRn tyvar 		`thenRn` \ tyvar' ->
    returnRn (MonoTyVar tyvar', unitFV tyvar')

rnHsType doc (MonoFunTy ty1 ty2)
  = rnHsType doc ty1	`thenRn` \ (ty1', fvs1) ->
    rnHsType doc ty2	`thenRn` \ (ty2', fvs2) ->
    returnRn (MonoFunTy ty1' ty2', fvs1 `plusFV` fvs2)

rnHsType doc (MonoListTy ty)
  = rnHsType doc ty				`thenRn` \ (ty', fvs) ->
    returnRn (MonoListTy ty', fvs `addOneFV` listTyCon_name)

rnHsType doc (MonoTupleTy tys boxed)
  = rnHsTypes doc tys			`thenRn` \ (tys', fvs) ->
    returnRn (MonoTupleTy tys' boxed, fvs `addOneFV` tup_con_name)
  where
    tup_con_name = tupleTyCon_name boxed (length tys)

rnHsType doc (MonoTyApp ty1 ty2)
  = rnHsType doc ty1		`thenRn` \ (ty1', fvs1) ->
    rnHsType doc ty2		`thenRn` \ (ty2', fvs2) ->
    returnRn (MonoTyApp ty1' ty2', fvs1 `plusFV` fvs2)

rnHsType doc (MonoDictTy clas tys)
  = lookupOccRn clas		`thenRn` \ clas' ->
    rnHsTypes doc tys		`thenRn` \ (tys', fvs) ->
    returnRn (MonoDictTy clas' tys', fvs `addOneFV` clas')

rnHsType doc (MonoUsgTy usg ty)
  = rnHsType doc ty             `thenRn` \ (ty', fvs) ->
    returnRn (MonoUsgTy usg ty', fvs)

rnHsTypes doc tys = mapFvRn (rnHsType doc) tys
\end{code}


\begin{code}
rnContext :: SDoc -> RdrNameContext -> RnMS (RenamedContext, FreeVars)

rnContext doc ctxt
  = mapAndUnzipRn rn_ctxt ctxt		`thenRn` \ (theta, fvs_s) ->
    let
	(_, dup_asserts) = removeDups cmp_assert theta
    in
	-- Check for duplicate assertions
	-- If this isn't an error, then it ought to be:
    mapRn_ (addWarnRn . dupClassAssertWarn theta) dup_asserts	`thenRn_`

    returnRn (theta, plusFVs fvs_s)
  where
    rn_ctxt (clas, tys)
      =	lookupOccRn clas		`thenRn` \ clas_name ->
	rnHsTypes doc tys		`thenRn` \ (tys', fvs) ->
	returnRn ((clas_name, tys'), fvs `addOneFV` clas_name)

    cmp_assert (c1,tys1) (c2,tys2)
      = (c1 `compare` c2) `thenCmp` (cmpHsTypes compare tys1 tys2)
\end{code}


%*********************************************************
%*							 *
\subsection{IdInfo}
%*							 *
%*********************************************************

\begin{code}
rnIdInfo (HsStrictness str) = returnRn (HsStrictness str, emptyFVs)

rnIdInfo (HsWorker worker)
  = lookupOccRn worker			`thenRn` \ worker' ->
    returnRn (HsWorker worker', unitFV worker')

rnIdInfo (HsUnfold inline (Just expr))	= rnCoreExpr expr `thenRn` \ (expr', fvs) ->
				  	  returnRn (HsUnfold inline (Just expr'), fvs)
rnIdInfo (HsUnfold inline Nothing)	= returnRn (HsUnfold inline Nothing, emptyFVs)
rnIdInfo (HsArity arity)	= returnRn (HsArity arity, emptyFVs)
rnIdInfo (HsUpdate update)	= returnRn (HsUpdate update, emptyFVs)
rnIdInfo (HsNoCafRefs)		= returnRn (HsNoCafRefs, emptyFVs)
rnIdInfo (HsCprInfo cpr_info)	= returnRn (HsCprInfo cpr_info, emptyFVs)
rnIdInfo (HsSpecialise rule_body) = rnRuleBody rule_body
				    `thenRn` \ (rule_body', fvs) ->
				    returnRn (HsSpecialise rule_body', fvs)

rnRuleBody (UfRuleBody str vars args rhs)
  = rnCoreBndrs vars		$ \ vars' ->
    mapFvRn rnCoreExpr args	`thenRn` \ (args', fvs1) ->
    rnCoreExpr rhs		`thenRn` \ (rhs',  fvs2) ->
    returnRn (UfRuleBody str vars' args' rhs', fvs1 `plusFV` fvs2)
\end{code}

@UfCore@ expressions.

\begin{code}
rnCoreExpr (UfType ty)
  = rnHsType (text "unfolding type") ty	`thenRn` \ (ty', fvs) ->
    returnRn (UfType ty', fvs)

rnCoreExpr (UfVar v)
  = lookupOccRn v 	`thenRn` \ v' ->
    returnRn (UfVar v', unitFV v')

rnCoreExpr (UfCon con args) 
  = rnUfCon con			`thenRn` \ (con', fvs1) ->
    mapFvRn rnCoreExpr args	`thenRn` \ (args', fvs2) ->
    returnRn (UfCon con' args', fvs1 `plusFV` fvs2)

rnCoreExpr (UfTuple con args) 
  = lookupOccRn con		`thenRn` \ con' ->
    mapFvRn rnCoreExpr args	`thenRn` \ (args', fvs) ->
    returnRn (UfTuple con' args', fvs `addOneFV` con')

rnCoreExpr (UfApp fun arg)
  = rnCoreExpr fun		`thenRn` \ (fun', fv1) ->
    rnCoreExpr arg		`thenRn` \ (arg', fv2) ->
    returnRn (UfApp fun' arg', fv1 `plusFV` fv2)

rnCoreExpr (UfCase scrut bndr alts)
  = rnCoreExpr scrut			`thenRn` \ (scrut', fvs1) ->
    bindCoreLocalFVRn bndr		( \ bndr' ->
	mapFvRn rnCoreAlt alts		`thenRn` \ (alts', fvs2) ->
	returnRn (UfCase scrut' bndr' alts', fvs2)
    )						`thenRn` \ (case', fvs3) ->
    returnRn (case', fvs1 `plusFV` fvs3)

rnCoreExpr (UfNote note expr) 
  = rnNote note			`thenRn` \ (note', fvs1) ->
    rnCoreExpr expr		`thenRn` \ (expr', fvs2) ->
    returnRn  (UfNote note' expr', fvs1 `plusFV` fvs2) 

rnCoreExpr (UfLam bndr body)
  = rnCoreBndr bndr 		$ \ bndr' ->
    rnCoreExpr body		`thenRn` \ (body', fvs) ->
    returnRn (UfLam bndr' body', fvs)

rnCoreExpr (UfLet (UfNonRec bndr rhs) body)
  = rnCoreExpr rhs		`thenRn` \ (rhs', fvs1) ->
    rnCoreBndr bndr 		( \ bndr' ->
	rnCoreExpr body		`thenRn` \ (body', fvs2) ->
	returnRn (UfLet (UfNonRec bndr' rhs') body', fvs2)
    )				`thenRn` \ (result, fvs3) ->
    returnRn (result, fvs1 `plusFV` fvs3)

rnCoreExpr (UfLet (UfRec pairs) body)
  = rnCoreBndrs bndrs		$ \ bndrs' ->
    mapFvRn rnCoreExpr rhss	`thenRn` \ (rhss', fvs1) ->
    rnCoreExpr body		`thenRn` \ (body', fvs2) ->
    returnRn (UfLet (UfRec (bndrs' `zip` rhss')) body', fvs1 `plusFV` fvs2)
  where
    (bndrs, rhss) = unzip pairs
\end{code}

\begin{code}
rnCoreBndr (UfValBinder name ty) thing_inside
  = rnHsType doc ty		`thenRn` \ (ty', fvs1) ->
    bindCoreLocalFVRn name	( \ name' ->
	    thing_inside (UfValBinder name' ty')
    )				`thenRn` \ (result, fvs2) ->
    returnRn (result, fvs1 `plusFV` fvs2)
  where
    doc = text "unfolding id"
    
rnCoreBndr (UfTyBinder name kind) thing_inside
  = bindCoreLocalFVRn name		$ \ name' ->
    thing_inside (UfTyBinder name' kind)
    
rnCoreBndrs []     thing_inside = thing_inside []
rnCoreBndrs (b:bs) thing_inside = rnCoreBndr b		$ \ name' ->
				  rnCoreBndrs bs 	$ \ names' ->
				  thing_inside (name':names')
\end{code}    

\begin{code}
rnCoreAlt (con, bndrs, rhs)
  = rnUfCon con				`thenRn` \ (con', fvs1) ->
    bindCoreLocalsFVRn bndrs		( \ bndrs' ->
	rnCoreExpr rhs			`thenRn` \ (rhs', fvs2) ->
	returnRn ((con', bndrs', rhs'), fvs2)
    )					`thenRn` \ (result, fvs3) ->
    returnRn (result, fvs1 `plusFV` fvs3)

rnNote (UfCoerce ty)
  = rnHsType (text "unfolding coerce") ty	`thenRn` \ (ty', fvs) ->
    returnRn (UfCoerce ty', fvs)

rnNote (UfSCC cc)   = returnRn (UfSCC cc, emptyFVs)
rnNote UfInlineCall = returnRn (UfInlineCall, emptyFVs)
rnNote UfInlineMe   = returnRn (UfInlineMe, emptyFVs)


rnUfCon UfDefault
  = returnRn (UfDefault, emptyFVs)

rnUfCon (UfDataCon con)
  = lookupOccRn con		`thenRn` \ con' ->
    returnRn (UfDataCon con', unitFV con')

rnUfCon (UfLitCon lit)
  = returnRn (UfLitCon lit, emptyFVs)

rnUfCon (UfLitLitCon lit ty)
  = rnHsType (text "litlit") ty		`thenRn` \ (ty', fvs) ->
    returnRn (UfLitLitCon lit ty', fvs)

rnUfCon (UfPrimOp op)
  = lookupOccRn op		`thenRn` \ op' ->
    returnRn (UfPrimOp op', emptyFVs)

rnUfCon (UfCCallOp str is_dyn casm gc)
  = returnRn (UfCCallOp str is_dyn casm gc, emptyFVs)
\end{code}

%*********************************************************
%*							 *
\subsection{Rule shapes}
%*							 *
%*********************************************************

Check the shape of a transformation rule LHS.  Currently
we only allow LHSs of the form @(f e1 .. en)@, where @f@ is
not one of the @forall@'d variables.

\begin{code}
validRuleLhs foralls lhs
  = check lhs
  where
    check (HsApp e1 e2) 		  = check e1
    check (HsVar v) | v `notElem` foralls = True
    check other				  = False
\end{code}


%*********************************************************
%*							 *
\subsection{Errors}
%*							 *
%*********************************************************

\begin{code}
derivingNonStdClassErr clas
  = hsep [ptext SLIT("non-standard class"), ppr clas, ptext SLIT("in deriving clause")]

classTyVarNotInOpTyErr clas_tyvar sig
  = hang (hsep [ptext SLIT("Class type variable"),
		       quotes (ppr clas_tyvar),
		       ptext SLIT("does not appear in method signature")])
	 4 (ppr sig)

dupClassAssertWarn ctxt (assertion : dups)
  = sep [hsep [ptext SLIT("Duplicate class assertion"), 
	       quotes (pprClassAssertion assertion),
	       ptext SLIT("in the context:")],
	 nest 4 (pprContext ctxt <+> ptext SLIT("..."))]

badDataCon name
   = hsep [ptext SLIT("Illegal data constructor name"), quotes (ppr name)]

forAllWarn doc ty tyvar
  | not opt_WarnUnusedMatches = returnRn ()
  | otherwise
  = getModeRn		`thenRn` \ mode ->
    case mode of {
#ifndef DEBUG
	InterfaceMode -> returnRn () ;	-- Don't warn of unused tyvars in interface files
					-- unless DEBUG is on, in which case it is slightly
					-- informative.  They can arise from mkRhsTyLam,
#endif					-- leading to (say) 	f :: forall a b. [b] -> [b]
	other ->

    addWarnRn (
      sep [ptext SLIT("The universally quantified type variable") <+> quotes (ppr tyvar),
	   nest 4 (ptext SLIT("does not appear in the type") <+> quotes (ppr ty))]
      $$
      (ptext SLIT("In") <+> doc))
    }

forAllErr doc ty tyvar
  = addErrRn (
      sep [ptext SLIT("The constrained type variable") <+> quotes (ppr tyvar),
	   nest 4 (ptext SLIT("does not appear in the type") <+> quotes (ppr ty))]
      $$
      (ptext SLIT("In") <+> doc))

ctxtErr explicit_forall doc tyvars constraint ty
  = sep [ptext SLIT("None of the type variable(s) in the constraint")
          <+> quotes (pprClassAssertion constraint),
	 if explicit_forall then
 	   nest 4 (ptext SLIT("is universally quantified (i.e. bound by the forall)"))
	 else
	   nest 4 (ptext SLIT("appears in the type") <+> quotes (ppr ty))
    ]
    $$
    (ptext SLIT("In") <+> doc)

badRuleLhsErr name lhs
  = sep [ptext SLIT("Rule") <+> ptext name <> colon,
	 nest 4 (ptext SLIT("Illegal left-hand side:") <+> ppr lhs)]
    $$
    ptext SLIT("LHS must be of form (f e1 .. en) where f is not forall'd")

badRuleVar name var
  = sep [ptext SLIT("Rule") <+> ptext name <> colon,
	 ptext SLIT("Forall'd variable") <+> quotes (ppr var) <+> 
		ptext SLIT("does not appear on left hand side")]
\end{code}
