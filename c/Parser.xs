/* $Id: Parser.xs,v 1.16 1999/11/05 11:15:55 gisle Exp $
 *
 * Copyright 1999, Gisle Aas.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the same terms as Perl itself.
 */

#ifdef __cplusplus
extern "C" {
#endif
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#ifdef __cplusplus
}
#endif

/* This is used to classify "letters" that can make up an HTML identifier
 * (tagname or attribute name) after the first strict ALFA char.  In addition
 * to what is allowed according to the SGML reference syntax we allow "_"
 * and ":".   The underscore is known to be used in Netscape bookmarks.html
 * files.  MicroSoft Excel use ":" in their HTML exports:
 *
 *  <A HREF="..." ADD_DATE="940656492" LAST_VISIT="941139558" LAST_MODIFIED="940656487">
 *  <div id="TSOH499L_24029" align=center x:publishsource="Excel">
 */

#define isHALNUM(c) (isALNUM(c) || (c) == '.' || (c) == '-' || (c) == ':')


struct p_state {
  SV* buf;

  int xmp;
  int strict_comment;
  int keep_case;
  int pass_cbdata;

  AV* accum;

  SV* text_cb;
  SV* start_cb;
  SV* end_cb;
  SV* decl_cb;
  SV* com_cb;
  SV* pi_cb;
};
typedef struct p_state PSTATE;


static SV*
sv_lower(SV* sv)
{
   STRLEN len;
   char *s = SvPV_force(sv, len);
   for (; len--; s++)
	*s = toLOWER(*s);
   return sv;
}


static void
html_text(PSTATE* p_state, char* beg, char *end, int cdata, SV* cbdata)
{
  AV *accum;
  SV *cb;

  if (beg == end)
    return;

  accum = p_state->accum;
  if (accum) {
    AV* av = newAV();
    av_push(av, newSVpv("T", 1));
    av_push(av, newSVpv(beg, end - beg));
    if (cdata)
      av_push(av, &PL_sv_yes);
    av_push(accum, (SV*)av);
    return;
  }

  cb = p_state->text_cb;
  if (cb) {
    dSP;
    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    if (p_state->pass_cbdata)
      XPUSHs(cbdata);
    XPUSHs(sv_2mortal(newSVpv(beg, end - beg)));
    if (cdata)
      XPUSHs(&PL_sv_yes);
    
    PUTBACK;

    perl_call_sv(cb, G_DISCARD);

    FREETMPS;
    LEAVE;
  }
}


static void
html_end(PSTATE* p_state,
	 char *tag_beg, char *tag_end,
	 char *beg, char *end,
	 SV* cbdata)
{
  AV *accum;
  SV *cb;

  accum = p_state->accum;
  if (accum) {
    AV* av = newAV();
    SV* tag = newSVpv(tag_beg, tag_end - tag_beg);
    if (!p_state->keep_case)
      sv_lower(tag);
    
    av_push(av, newSVpv("E", 1));
    av_push(av, tag);
    av_push(av, newSVpv(beg, end - beg));
    av_push(accum, (SV*)av);
    return;
  }

  cb = p_state->end_cb;
  if (cb) {
    SV *sv;
    dSP;
    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    if (p_state->pass_cbdata)
      XPUSHs(cbdata);
    sv = sv_2mortal(newSVpv(tag_beg, tag_end - tag_beg));
    if (!p_state->keep_case)
      sv_lower(sv);
    XPUSHs(sv);
    XPUSHs(sv_2mortal(newSVpv(beg, end - beg)));
    PUTBACK;

    perl_call_sv(cb, G_DISCARD);

    FREETMPS;
    LEAVE;
  }
}


static void
html_start(PSTATE* p_state,
	   char *tag_beg, char *tag_end,
	   AV* tokens,
	   char *beg, char *end,
	   SV* cbdata)
{
  AV *accum;
  SV *cb;

  accum = p_state->accum;
  if (accum) {
    AV* av = newAV();
    SV* tag = newSVpv(tag_beg, tag_end - tag_beg);
    if (!p_state->keep_case)
      sv_lower(tag);
    
    av_push(av, newSVpv("S", 1));
    av_push(av, tag);
    av_push(av, (SV*)tokens);
    SvREFCNT_inc(tokens);
    av_push(av, newSVpv(beg, end - beg));
    av_push(accum, (SV*)av);
    return;
  }

  cb = p_state->start_cb;
  if (cb) {
    SV *sv;
    dSP;
    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    if (p_state->pass_cbdata)
      XPUSHs(cbdata);
    sv = sv_2mortal(newSVpv(tag_beg, tag_end - tag_beg));
    if (!p_state->keep_case)
      sv_lower(sv);
    XPUSHs(sv);
    XPUSHs(sv_2mortal(newRV_inc((SV*)tokens)));
    XPUSHs(sv_2mortal(newSVpvn(beg, end - beg)));
    PUTBACK;

    perl_call_sv(cb, G_DISCARD);

    FREETMPS;
    LEAVE;
  }
}


static void
html_process(PSTATE* p_state, char*beg, char *end, SV* cbdata)
{
  AV *accum;
  SV *cb;

  accum = p_state->accum;
  if (accum) {
    AV* av = newAV();
    av_push(av, newSVpv("P", 1));
    av_push(av, newSVpvn(beg, end - beg));
    av_push(accum, (SV*)av);
    return;
  }

  cb = p_state->pi_cb;
  if (cb) {
    dSP;
    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    if (p_state->pass_cbdata)
      XPUSHs(cbdata);
    XPUSHs(sv_2mortal(newSVpvn(beg, end - beg)));
    PUTBACK;

    perl_call_sv(cb, G_DISCARD);

    FREETMPS;
    LEAVE;
  }
}


static void
html_comment(PSTATE* p_state, char *beg, char *end, SV* cbdata)
{
  AV *accum;
  SV *cb;

  accum = p_state->accum;
  if (accum) {
    AV* av = newAV();
    av_push(av, newSVpv("C", 1));
    av_push(av, newSVpvn(beg, end - beg));
    av_push(accum, (SV*)av);
    return;
  }

  cb = p_state->com_cb;
  if (cb) {
    dSP;
    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    if (p_state->pass_cbdata)
      XPUSHs(cbdata);
    XPUSHs(sv_2mortal(newSVpvn(beg, end - beg)));
    PUTBACK;

    perl_call_sv(cb, G_DISCARD);

    FREETMPS;
    LEAVE;
  }
}


static void
html_decl(PSTATE* p_state, AV* tokens, char *beg, char *end, SV* cbdata)
{
  AV *accum;
  SV *cb;

  accum = p_state->accum;
  if (accum) {
    AV* av = newAV();
    av_push(av, newSVpv("D", 1));
    av_push(av, (SV*)tokens);
    SvREFCNT_inc(tokens);
    av_push(av, newSVpv(beg, end - beg));
    av_push(accum, (SV*)av);
    return;
  }

  cb = p_state->decl_cb;
  if (cb) {
    dSP;
    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    if (p_state->pass_cbdata)
      XPUSHs(cbdata);
    XPUSHs(sv_2mortal(newRV_inc((SV*)tokens)));
    XPUSHs(sv_2mortal(newSVpvn(beg, end - beg)));
    PUTBACK;

    perl_call_sv(cb, G_DISCARD);

    FREETMPS;
    LEAVE;
  }
}



static char*
html_parse_decl(PSTATE* p_state, char *beg, char *end, SV* cbdata)
{
  char *s = beg;

  assert(end - beg >= 1);

  if (isALPHA(*s)) {
    AV* tokens = newAV();
    s++;
    /* declaration */
    while (s < end && isHALNUM(*s))
      s++;
    /* first word available */
    av_push(tokens, newSVpv(beg, s - beg));

    while (s < end && isSPACE(*s)) {
      s++;
      while (s < end && isSPACE(*s))
	s++;

      if (s == end)
	goto PREMATURE;

      if (*s == '"' || *s == '\'') {
	char *str_beg = s;
	s++;
	while (s < end && *s != *str_beg)
	  s++;
	if (s == end)
	  goto PREMATURE;
	s++;
	av_push(tokens, newSVpv(str_beg, s - str_beg));
      }
      else if (*s == '-') {
	/* comment */
	char *com_beg = s;
	s++;
	if (s == end)
	  goto PREMATURE;
	if (*s != '-')
	  goto ERROR;
	s++;

	while (1) {
	  while (s < end && *s != '-')
	    s++;
	  if (s == end)
	    goto PREMATURE;
	  s++;
	  if (s == end)
	    goto PREMATURE;
	  if (*s == '-') {
	    s++;
	    av_push(tokens, newSVpv(com_beg, s - com_beg));
	    break;
	  }
	}
      }
      else if (*s != '>') {
	/* plain word */
	char *word_beg = s;
	s++;
	while (s < end && !isSPACE(*s) && *s != '>')
	  s++;
	if (s == end)
	  goto PREMATURE;
	av_push(tokens, newSVpv(word_beg, s - word_beg));
      }
      else {
	break;
      }
    }

    if (s == end)
      goto PREMATURE;
    if (*s == '>') {
      s++;
      html_decl(p_state, tokens, beg, s-1, cbdata);
      if (tokens)
	SvREFCNT_dec(tokens);
      return s;
    }

  ERROR:
    if (tokens)
      SvREFCNT_dec(tokens);
    return 0;

  PREMATURE:
    if (tokens)
      SvREFCNT_dec(tokens);
    return beg;

  } else if (*s == '-') {
    s++;
    /* comment? */
    if (s == end)
      return beg;

    if (*s == '-') {
      s++;
      /* yes, two dashes seen; it is really a comment */

      if (p_state->strict_comment) {
	AV* av = newAV();  /* used to collect comments until we seen them all */
	char *start_com = s;  /* also used to signal inside/outside */

	while (1) {
	  /* try to locate "--" */
	FIND_DASH_DASH:
	  // printf("find_dash_dash: [%s]\n", s);
	  while (s < end && *s != '-' && *s != '>')
	    s++;

	  if (s == end) {
	    SvREFCNT_dec(av);
	    return beg;
	  }

	  if (*s == '>') {
	    s++;
	    if (start_com)
	      goto FIND_DASH_DASH;

	    /* we are done recognizing all comments, make callbacks */
	    {
	      int i;
	      int len = av_len(av);
	      for (i = 0; i <= len; i++) {
		SV** svp = av_fetch(av, i, 0);
		if (svp) {
		  STRLEN len;
		  char *s = SvPV(*svp, len);
		  html_comment(p_state, s, s+len, cbdata);
		}
	      }
	    }

	    SvREFCNT_dec(av);
	    return s;
	  }

	  s++;
	  if (s == end) {
	    SvREFCNT_dec(av);
	    return beg;
	  }

	  if (*s == '-') {
	    /* two dashes in a row seen */
	    s++;
	    /* do something */
	    if (start_com) {
	      av_push(av, newSVpvn(start_com, s - start_com - 2));
	      start_com = 0;
	    }
	    else {
	      start_com = s;
	    }
	  }
	}
      }
      else /* non-strict comment */
      {
	char *end_com;
	/* try to locate /--\s*>/ which signals end-of-comment */
      LOCATE_END:
	while (s < end && *s != '-')
	  s++;
	end_com = s;
	if (s < end) {
	  s++;
	  if (s < end && *s == '-') {
	    s++;
	    while (s < end && isSPACE(*s))
	      s++;
	    if (s < end && *s == '>') {
	      s++;
	      /* yup */
	      html_comment(p_state, beg+2, end_com, cbdata);
	      return s;
	    }
	  }
	  if (s < end) {
	    s = end_com + 2;
	    goto LOCATE_END;
	  }
	}
	
	if (s == end)
	  return beg;
      }
    }
  }
  return 0;
}



static char*
html_parse_start(PSTATE* p_state, char *beg, char *end, SV* cbdata)
{
  char *s = beg;
  char *tag_end;
  AV* tokens = 0;
  SV* sv;

  assert(beg[0] == '<' && isALPHA(beg[1]) && end - beg > 2);
  s += 2;

  while (s < end && isHALNUM(*s))
    s++;
  tag_end = s;
  while (s < end && isSPACE(*s))
    s++;
  if (s == end)
    goto PREMATURE;

  tokens = newAV();

  while (isALPHA(*s)) {
    /* attribute */
    char *attr_beg = s;
    s++;
    while (s < end && isHALNUM(*s))
      s++;

    sv = newSVpv(attr_beg, s - attr_beg);
    if (!p_state->keep_case)
      sv_lower(sv);
    av_push(tokens, sv);

    while (s < end && isSPACE(*s))
      s++;
    if (s == end)
      goto PREMATURE;

    if (*s == '=') {
      /* with a value */
      s++;
      while (s < end && isSPACE(*s))
	s++;
      if (s == end)
	goto PREMATURE;
      if (*s == '>') {
	/* parse it similar to ="" */
	av_push(tokens, newSVpvn("", 0));
	break;
      }
      if (*s == '"' || *s == '\'') {
	char *str_beg = s;
	s++;
	while (s < end && *s != *str_beg)
	  s++;
	if (s == end)
	  goto PREMATURE;
	s++;
	av_push(tokens, newSVpvn(str_beg+1, s - str_beg - 2));
      }
      else {
	char *word_start = s;
	while (s < end && !isSPACE(*s) && *s != '>')
	  s++;
	if (s == end)
	  goto PREMATURE;
	av_push(tokens, newSVpv(word_start, s - word_start));
      }

      while (s < end && isSPACE(*s))
	s++;
      if (s == end)
	goto PREMATURE;
    }
    else {
      av_push(tokens, &PL_sv_yes);
    }
  }

  if (*s == '>') {
    s++;
    /* done */
    html_start(p_state, beg+1, tag_end, tokens, beg, s, cbdata);
    if (tokens)
      SvREFCNT_dec(tokens);

    if (tag_end - beg == 4 &&
	toLOWER(beg[1]) == 'x' &&
	toLOWER(beg[2]) == 'm' &&
	toLOWER(beg[3]) == 'p')
      p_state->xmp++;

    return s;
  }
  if (tokens)
    SvREFCNT_dec(tokens);
  return 0;

 PREMATURE:
  if (tokens)
    SvREFCNT_dec(tokens);
  return beg;
}



static void
html_parse(PSTATE* p_state,
	   SV* chunk,
	   SV* cbdata)
{
  char *s, *t, *end;
  STRLEN len;

#if 0
  {
    STRLEN len;
    char *s;

    printf("html_parse\n");
    if (p_state->buf) {
      s = SvPV(p_state->buf, len);
      printf("  buf   = [%s]\n", s);
    }
    if (chunk && SvOK(chunk)) {
      s = SvPV(chunk, len);
      printf("  chunk = [%s]\n", s);
    }
  }
#endif

  if (!chunk || !SvOK(chunk)) {
    /* EOF */
    if (p_state->buf) {
      /* flush it */
      STRLEN len;
      char *s = SvPV(p_state->buf, len);
      html_text(p_state, s, s+len, 0, cbdata);
      SvREFCNT_dec(p_state->buf);
      p_state->buf = 0;
    }
    return;
  }


  if (p_state->buf && SvOK(p_state->buf)) {
    sv_catsv(p_state->buf, chunk);
    s = SvPV(p_state->buf, len);
  }
  else {
    s = SvPV(chunk, len);
  }

  if (!len)
    return; /* nothing to do */

  t = s;
  end = s + len;

  while (1) {
    /*
     * At the start of this loop we will always be ready for eating text
     * or a new tag.  We will never be inside some tag.  The 't' point
     * to where we started and the 's' is advanced as we go.
     */

    while (p_state->xmp) {
      char *end_text;

      while (s < end && *s != '<')
	s++;
      if (s == end)
	goto DONE;

      end_text = s;
      s++;
      
      /* here we rely on '\0' termination of perl svpv buffers */
      if (*s == '/') {
	s++;
	if (toLOWER(*s) == 'x') {
	  s++;
	  if (toLOWER(*s) == 'm') {
	    s++;
	    if (toLOWER(*s) == 'p') {
	      s++;
	      while (isSPACE(*s))
		s++;
	      if (*s == '>') {
		/* end */
		s++;
		html_text(p_state, t, end_text, 1, cbdata);
		html_end(p_state, end_text+2, end_text+5,
			          end_text, s, cbdata);
		p_state->xmp = 0;
		t = s;
	      }
	    }
	  }
	}
      }
    }

    /* first we try to match as much text as possible */
    while (s < end && *s != '<')
      s++;
    if (s != t) {
      if (*s == '<') {
	html_text(p_state, t, s, 0, cbdata);
	t = s;
      }
      else {
	s--;
	if (isSPACE(*s)) {
	  /* wait with white space at end */
	  while (s >= t && isSPACE(*s))
	    s--;
	}
	else {
	  /* might be a chopped up entities/words */
	  while (s >= t && !isSPACE(*s))
	    s--;
	  while (s >= t && isSPACE(*s))
	    s--;
	}
	s++;
	html_text(p_state, t, s, 0, cbdata);
	break;
      }
    }

    if (end - s < 3)
      break;

    /* next char is known to be '<' */
    s++;

    if (isALPHA(*s)) {
      /* start tag */
      char *new_pos = html_parse_start(p_state, t, end, cbdata);
      if (new_pos == t) {
	s = t;
	break;
      }	
      else if (new_pos)
	t = s = new_pos;
    }
    else if (*s == '/') {
      /* end tag */
      s++;
      if (isALPHA(*s)) {
	char *tag_start = s;
	char *tag_end;
	s++;
	while (s < end && isHALNUM(*s))
	  s++;
	tag_end = s;
	while (s < end && isSPACE(*s))
	  s++;
	if (s < end) {
	  if (*s == '>') {
	    s++;
	    /* a complete end tag has been recognized */
	    html_end(p_state, tag_start, tag_end, t, s, cbdata);
	    t = s;
	  }
	}
	else {
	  s = t;
	  break;  /* need to see more stuff */
	}
      }
    }
    else if (*s == '!') {
      /* declaration or comment */
      char *new_pos;
      s++;
      new_pos = html_parse_decl(p_state, s, end, cbdata);
      if (new_pos == s) {
	/* no progress, need more */
	s = t;
	break;
      }
      else if (new_pos) {
	t = s = new_pos;
      }
    }
    else if (*s == '?') {
      /* processing instruction */
      s++;
      while (s < end && *s != '>')
	s++;
      if (*s == '>') {
	s++;
	/* a complete processing instruction seen */
	html_process(p_state, t+2, s-1, cbdata);
	t = s;
      }
      else {
	/* need more */
	s = t;
	break;
      }
    }

    /* if we get out here thene this was not a conforming tag, so
     * treat it is plain text.
     */
  }

 DONE:

  if (s == end) {
    if (p_state->buf) {
      SvOK_off(p_state->buf);
    }
  }
  else {
    /* need to keep rest in buffer */
    if (p_state->buf) {
      /* chop off some chars at the beginning */
      if (SvOK(p_state->buf))
	sv_chop(p_state->buf, s);
      else
	sv_setpvn(p_state->buf, s, end - s);
    }
    else {
      p_state->buf = newSVpv(s, end - s);
    }
  }
  return;
}



static PSTATE*
get_pstate(SV* sv)
{
  HV* hv;
  SV** svp;

  sv = SvRV(sv);
  if (!sv || SvTYPE(sv) != SVt_PVHV)
    croak("Not a reference to a hash");
  hv = (HV*)sv;
  svp = hv_fetch(hv, "_parser_xs_state", 16, 0);
  if (svp)
    return (PSTATE*)SvIV(*svp);
  croak("Can't find '_parser_xs_state' element in HTML::Parser hash");
  return 0;
}



MODULE = HTML::Parser		PACKAGE = HTML::Parser

PROTOTYPES: DISABLE

void
_alloc_pstate(self)
	SV* self;
    PREINIT:
	PSTATE* pstate;
	SV* sv;
	HV* hv;
    CODE:
	sv = SvRV(self);
        if (!sv || SvTYPE(sv) != SVt_PVHV)
            croak("Self is not a reference to a hash");
	hv = (HV*)sv;

	Newz(56, pstate, 1, PSTATE);
	sv = newSViv((IV)pstate);
	SvREADONLY_on(sv);

	hv_store(hv, "_parser_xs_state", 16, sv, 0);

void
DESTROY(pstate)
	PSTATE* pstate
    CODE:
	SvREFCNT_dec(pstate->buf);
        SvREFCNT_dec(pstate->accum);
	SvREFCNT_dec(pstate->text_cb);
	SvREFCNT_dec(pstate->start_cb);
	SvREFCNT_dec(pstate->end_cb);
	SvREFCNT_dec(pstate->decl_cb);
	SvREFCNT_dec(pstate->com_cb);
	SvREFCNT_dec(pstate->pi_cb);
	Safefree(pstate);


void
parse(self, chunk)
	SV* self;
	SV* chunk
    PREINIT:
	PSTATE* pstate = get_pstate(self);
    PPCODE:
	html_parse(pstate, chunk, self);
	XSRETURN(1); /* self */

int
strict_comment(pstate,...)
	PSTATE* pstate
    CODE:
	RETVAL = pstate->strict_comment;
	if (items > 1)
	    pstate->strict_comment = SvTRUE(ST(1));
    OUTPUT:
	RETVAL

int
pass_cbdata(pstate,...)
	PSTATE* pstate
    CODE:
	RETVAL = pstate->pass_cbdata;
	if (items > 1)
	    pstate->pass_cbdata = SvTRUE(ST(1));
    OUTPUT:
	RETVAL

int
keep_case(pstate,...)
	PSTATE* pstate
    CODE:
	RETVAL = pstate->keep_case;
	if (items > 1)
	    pstate->keep_case = SvTRUE(ST(1));
    OUTPUT:
	RETVAL

SV*
accum(pstate,...)
	PSTATE* pstate
    CODE:
        RETVAL = pstate->accum ? newRV_inc((SV*)pstate->accum)
	                       : &PL_sv_undef;
        if (items > 1) {
	    SV* aref = ST(1);
            AV* av = (AV*)SvRV(aref);
            if (!av || SvTYPE(av) != SVt_PVAV)
		croak("accum argument is not an array reference");
	    SvREFCNT_dec(pstate->accum);
	    pstate->accum = av;
	    SvREFCNT_inc(pstate->accum);
        }
    OUTPUT:
	RETVAL

void
callback(pstate, name_sv, cb)
	PSTATE* pstate
	SV* name_sv
	SV* cb
    PREINIT:
	STRLEN name_len;
	char *name = SvPV(name_sv, name_len);
	SV** svp = 0;
    CODE:
	switch (name_len) {
	case 3:
	    if (strEQ(name, "end"))
		svp = &pstate->end_cb;
	    break;
	case 4:
	    if (strEQ(name, "text"))
		svp = &pstate->text_cb;
	    break;
	case 5:
	    if (strEQ(name, "start"))
		svp = &pstate->start_cb;
	    break;
	case 7:
	    if (strEQ(name, "comment"))
		svp = &pstate->com_cb;
	    if (strEQ(name, "process"))
		svp = &pstate->pi_cb;
	    break;
	case 11:
	    if (strEQ(name, "declaration"))
		svp = &pstate->decl_cb;
	    break;
	}

	if (svp) {
	    SvREFCNT_dec(*svp);
	    *svp = SvREFCNT_inc(cb);
	}
	else
	    croak("Can't set %s callback", name);

