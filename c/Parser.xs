/* $Id: Parser.xs,v 1.10 1999/11/03 21:00:23 gisle Exp $
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

#define isHALNUM(c) (isALNUM(c) || (c) == '.' || (c) == '-')


struct p_state {
  SV* buf;

  int strict_comment;
  int pass_cbdata;

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
html_text(PSTATE* p_state, char* beg, char *end, SV* cbdata)
{
  SV *cb;
  if (beg == end)
    return;
  cb = p_state->text_cb;
  if (cb) {
    dSP;
    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    if (p_state->pass_cbdata)
      XPUSHs(cbdata);
    XPUSHs(sv_2mortal(newSVpv(beg, end - beg)));
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
  SV *cb = p_state->end_cb;
  if (cb) {
    SV tagsv;
    dSP;
    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    if (p_state->pass_cbdata)
      XPUSHs(cbdata);
    XPUSHs(sv_2mortal(sv_lower(newSVpv(tag_beg, tag_end - tag_beg))));
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
  SV *cb = p_state->start_cb;
  if (cb) {
    dSP;
    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    if (p_state->pass_cbdata)
      XPUSHs(cbdata);
    XPUSHs(sv_2mortal(sv_lower(newSVpv(tag_beg, tag_end - tag_beg))));
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
  SV *cb = p_state->pi_cb;
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
  SV *cb = p_state->com_cb;
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
  SV *cb = p_state->decl_cb;
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
      /* yes, it is really a comment */
      
# if 0
      if (p_state->strict_comment) {
	/* XXX */
      }
      else
#endif
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
    av_push(tokens, sv_lower(newSVpv(attr_beg, s - attr_beg)));

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
      html_text(p_state, s, s+len, cbdata);
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

    /* first we try to match as much text as possible */
    while (s < end && *s != '<')
      s++;
    if (s != t) {
      if (*s == '<') {
	html_text(p_state, t, s, cbdata);
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
	html_text(p_state, t, s, cbdata);
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

int
pass_cbdata(pstate,...)
	PSTATE* pstate
    CODE:
	RETVAL = pstate->pass_cbdata;
	if (items > 1)
	     pstate->pass_cbdata = SvTRUE(ST(1));


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

