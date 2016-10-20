var mainQANPage = require('./mainQan.po.js')
   
describe('Main QAN Page', function () {
 
  beforeEach(function () {
    browser.ignoreSynchronization = false;
    mainQANPage.get();
    element.all(by.css('.alert.msg')).then(function(items)  {
    expect(items.length).toBe(0);
    });
    //expect(element(by.css('.alert-danger')).isPresent()).toBe(false);
    expect(mainQANPage.returnTopTitle()).toContain('Top');
  });
  
  afterEach(function() {
    browser.manage().logs().get('browser').then(function(browserLog) {
    console.log('log: ' + require('util').inspect(browserLog));
    });
  });

  it('should search Select query', function () {
    mainQANPage.clearSearch();
    mainQANPage.searchFor('select');
    mainQANPage.doSearch();
    expect(mainQANPage.returnTopTitle()).toContain('Top');
    mainQANPage.clearSearch();
    mainQANPage.doSearch();
    expect(mainQANPage.returnTopTitle()).toContain('Top');
  });

  it('shouldnt search any query', function () {
    mainQANPage.clearSearch();
    mainQANPage.searchFor('querry');
    mainQANPage.doSearch();
    expect(mainQANPage.returnNoQueriesTxt()).toContain('There is no data');
    mainQANPage.clearSearch();
    mainQANPage.doSearch();
    expect(mainQANPage.returnTopTitle()).toContain('Top');
  });
  
  it('should click Select query', function () {
    mainQANPage.clearSearch();
    mainQANPage.searchFor('select');
    mainQANPage.doSearch();
    mainQANPage.clickQueryNr(0);
    mainQANPage.clickExample();
    mainQANPage.clickFingerprint();
  });

  it('should add db.table', function () {
    var tableValid = 'mysql.user';
    mainQANPage.clickQueryNr(1);
    mainQANPage.addTable(tableValid);
    mainQANPage.clickAddedTable(tableValid);
    mainQANPage.existCreateTable();
    expect(element(by.css('.alert-danger')).isPresent()).toBe(false);
  });

  it('should open Server Summary page', function () {
    mainQANPage.clickSummary();
    element(by.xpath('//*[contains(text(), "Server Summary")]'));
  });

  it('should click on Total', function () {
    mainQANPage.clickTotal();
  });

  it('should click on management button', function () {
    mainQANPage.clickManagement();
    expect(browser.getCurrentUrl()).toContain('/qan/#/management/mysql');
  });

});
